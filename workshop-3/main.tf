# Definiert AWS als Cloud-Provider und legt us-east-1 als Region fest; Zugangsdaten kommen aus Umgebungsvariablen
provider "aws" {
  region = "us-east-1"
}

# Ermittelt automatisch das neueste offizielle Ubuntu 22.04 LTS Image anhand der Canonical-Owner-ID
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  # Filtert nach dem 64-Bit x86 Server-Image von Ubuntu Jammy 22.04 mit SSD-Speicher
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  # Beschraenkt die Suche auf HVM-Virtualisierung, wie sie von t2.micro benoetigt wird
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Erzeugt ein isoliertes Virtual Private Cloud (VPC) mit privatem IP-Adressraum und aktivem DNS
resource "aws_vpc" "workshop_vpc" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "workshop-3-vpc"
  }
}

# Erstellt ein Internet Gateway, damit Ressourcen im VPC mit dem Internet kommunizieren koennen
resource "aws_internet_gateway" "workshop_igw" {
  vpc_id = aws_vpc.workshop_vpc.id

  tags = {
    Name = "workshop-3-igw"
  }
}

# Definiert eine Routing-Tabelle, die allen ausgehenden Traffic (0.0.0.0/0) an das Internet Gateway leitet
resource "aws_route_table" "workshop_public_rt" {
  vpc_id = aws_vpc.workshop_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.workshop_igw.id
  }

  tags = {
    Name = "workshop-3-public-rt"
  }
}

# Legt das erste oeffentliche Subnet in der Availability Zone us-east-1a an
resource "aws_subnet" "workshop_public_subnet_1" {
  vpc_id                  = aws_vpc.workshop_vpc.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "workshop-3-public-subnet-1"
  }
}

# Legt ein zweites oeffentliches Subnet in us-east-1b an, da ein Application Load Balancer mindestens zwei AZs verlangt
resource "aws_subnet" "workshop_public_subnet_2" {
  vpc_id                  = aws_vpc.workshop_vpc.id
  cidr_block              = "10.10.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "workshop-3-public-subnet-2"
  }
}

# Verknuepft das erste Subnet mit der oeffentlichen Routing-Tabelle fuer den Internetzugang
resource "aws_route_table_association" "workshop_rta_1" {
  subnet_id      = aws_subnet.workshop_public_subnet_1.id
  route_table_id = aws_route_table.workshop_public_rt.id
}

# Verknuepft das zweite Subnet ebenfalls mit der oeffentlichen Routing-Tabelle
resource "aws_route_table_association" "workshop_rta_2" {
  subnet_id      = aws_subnet.workshop_public_subnet_2.id
  route_table_id = aws_route_table.workshop_public_rt.id
}

# Erstellt eine Security Group fuer den Application Load Balancer, die HTTP-Anfragen aus dem Internet annimmt
resource "aws_security_group" "alb_sg" {
  name        = "workshop-3-alb-sg"
  description = "Erlaubt eingehenden HTTP-Traffic auf Port 80 fuer den Load Balancer"
  vpc_id      = aws_vpc.workshop_vpc.id

  # Oeffnet Port 80 (HTTP) weltweit fuer eingehende Browser-Anfragen an den Load Balancer
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Erlaubt dem Load Balancer ausgehenden Traffic zu den Ziel-Instanzen im VPC
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "workshop-3-alb-sg"
  }
}

# Erstellt eine eigene Security Group fuer die Webserver-Instanzen, die nur HTTP vom Load Balancer zulaesst
resource "aws_security_group" "web_sg" {
  name        = "workshop-3-web-sg"
  description = "Erlaubt HTTP auf Port 80 ausschliesslich vom Load Balancer und ausgehenden Internetzugriff"
  vpc_id      = aws_vpc.workshop_vpc.id

  # Laesst eingehenden HTTP-Traffic auf Port 80 nur zu, wenn er ueber die Security Group des ALB kommt
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # Erlaubt allen ausgehenden Traffic, damit die Instanzen beim Start Apache2 per apt-get herunterladen koennen
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "workshop-3-web-sg"
  }
}

# Startet zwei identische Ubuntu-Webserver verteilt auf die beiden Subnets in us-east-1a und us-east-1b
resource "aws_instance" "web_servers" {
  count                       = 2
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.micro"
  subnet_id                   = element([aws_subnet.workshop_public_subnet_1.id, aws_subnet.workshop_public_subnet_2.id], count.index)
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = true

  # Installiert Apache2 beim ersten Bootvorgang und gibt den jeweiligen Hostnamen aus, um Load Balancing sichtbar zu machen
  user_data = <<-EOF
              #!/bin/bash
              sudo apt-get update
              sudo apt-get install -y apache2
              sudo systemctl start apache2
              sudo systemctl enable apache2
              echo "<h1>Hello World von Server $(hostname -f)</h1>" | sudo tee /var/www/html/index.html
              EOF

  tags = {
    Name = "Terraform-Workshop-3-Webserver-${count.index + 1}"
  }
}

# Erstellt den oeffentlichen Application Load Balancer (ALB) ueber beide Subnets hinweg
resource "aws_lb" "web_alb" {
  name               = "workshop-3-web-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.workshop_public_subnet_1.id, aws_subnet.workshop_public_subnet_2.id]

  tags = {
    Name = "workshop-3-web-alb"
  }
}

# Definiert eine Target Group auf Port 80 (HTTP), in der die gesunden Ziel-Instanzen gebuendelt werden
resource "aws_lb_target_group" "web_tg" {
  name     = "workshop-3-web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.workshop_vpc.id

  # Prueft regelmaessig ueber HTTP GET auf /, ob Apache2 auf den Instanzen erreichbar ist
  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "workshop-3-web-tg"
  }
}

# Registriert beide erzeugten EC2-Instanzen als Ziele in der Target Group des Load Balancers
resource "aws_lb_target_group_attachment" "web_tg_attachment" {
  count            = length(aws_instance.web_servers)
  target_group_arn = aws_lb_target_group.web_tg.arn
  target_id        = aws_instance.web_servers[count.index].id
  port             = 80
}

# Richtet einen HTTP-Listener auf Port 80 am Load Balancer ein und leitet Anfragen an die Target Group weiter
resource "aws_lb_listener" "web_http_listener" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = 80
  protocol          = "HTTP"

  # Standardaktion: Alle eingehenden HTTP-Requests an die hinterlegte Target Group weiterleiten
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

# Gibt die oeffentliche DNS-Adresse des Application Load Balancers nach dem Deployment im Terminal aus
output "load_balancer_dns" {
  description = "DNS-Adresse des Application Load Balancers fuer den Zugriff im Browser"
  value       = aws_lb.web_alb.dns_name
}
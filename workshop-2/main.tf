# Definiert AWS als Provider und setzt us-east-1 als Zielregion; Zugangsdaten kommen ueber Umgebungsvariablen
provider "aws" {
  region = "us-east-1"
}

# Sucht automatisch das aktuellste offizielle Ubuntu 22.04 LTS Image ueber die Canonical-Owner-ID
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  # Filtert gezielt nach dem Ubuntu Jammy 22.04 Server-Image fuer 64-Bit x86 mit SSD
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  # Stellt sicher, dass nur HVM-Images in die Auswahl fallen
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Erzeugt ein eigenes VPC mit privatem Adressbereich und aktivierter DNS-Unterstuetzung
resource "aws_vpc" "workshop_vpc" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "workshop-2-vpc"
  }
}

# Legt ein Internet Gateway an, damit das VPC Verbindungen ins oeffentliche Internet aufbauen kann
resource "aws_internet_gateway" "workshop_igw" {
  vpc_id = aws_vpc.workshop_vpc.id

  tags = {
    Name = "workshop-2-igw"
  }
}

# Erstellt eine eigene Route Table und schickt allen nicht-lokalen Traffic (0.0.0.0/0) ans Internet Gateway
resource "aws_route_table" "workshop_public_rt" {
  vpc_id = aws_vpc.workshop_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.workshop_igw.id
  }

  tags = {
    Name = "workshop-2-public-rt"
  }
}

# Erstellt ein Subnet im VPC innerhalb der Availability Zone us-east-1a
resource "aws_subnet" "workshop_public_subnet" {
  vpc_id            = aws_vpc.workshop_vpc.id
  cidr_block        = "10.10.1.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "workshop-2-public-subnet"
  }
}

# Verknuepft das Subnet mit der Custom Route Table, sodass die Standardroute zum Internet Gateway aktiv wird
resource "aws_route_table_association" "workshop_rta" {
  subnet_id      = aws_subnet.workshop_public_subnet.id
  route_table_id = aws_route_table.workshop_public_rt.id
}

# Erstellt eine Security Group im eigenen VPC fuer eingehendes HTTP und beliebigen ausgehenden Traffic
resource "aws_security_group" "web_sg" {
  name        = "workshop-2-allow-http"
  description = "Erlaubt HTTP auf Port 80 eingehend und allen Traffic ausgehend"
  vpc_id      = aws_vpc.workshop_vpc.id

  # Oeffnet TCP-Port 80 (HTTP) fuer alle Quell-IPs, damit der Webserver im Browser erreichbar ist
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Erlaubt jeglichen ausgehenden Traffic (Protokoll -1), z. B. fuer apt-get und Paketdownloads
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "workshop-2-web-sg"
  }
}

# Erstellt ein Network Interface mit fester privater IP im Subnet und weist die Security Group zu
resource "aws_network_interface" "web_nic" {
  subnet_id       = aws_subnet.workshop_public_subnet.id
  private_ips     = ["10.10.1.10"]
  security_groups = [aws_security_group.web_sg.id]

  tags = {
    Name = "workshop-2-web-nic"
  }
}

# Erstellt die EC2-Instanz mit Ubuntu-Image, t2.micro und Apache-Startskript ueber das primaere Network Interface
resource "aws_instance" "web_server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"

  # Nutzt die vorbereitete Netzwerkkarte direkt als primaeres Interface (inkl. Subnet, fester IP und Security Group)
  primary_network_interface {
    network_interface_id = aws_network_interface.web_nic.id
  }

  # Installiert beim ersten Start Apache2, aktiviert den Dienst und schreibt die Hello-World-Seite
  user_data = <<-EOF
              #!/bin/bash
              sudo apt-get update
              sudo apt-get install -y apache2
              sudo systemctl start apache2
              sudo systemctl enable apache2
              echo "<h1>Hello World</h1>" | sudo tee /var/www/html/index.html
              EOF

  tags = {
    Name = "Terraform-Workshop-2-Webserver"
  }
}

# Reserviert eine Elastic IP und weist sie dem Network Interface zu, sobald IGW und Instanz bereit sind
resource "aws_eip" "web_eip" {
  domain            = "vpc"
  network_interface = aws_network_interface.web_nic.id

  # Stellt sicher, dass IGW und Instanz zuerst stehen, bevor die Elastic IP gebunden wird
  depends_on = [
    aws_internet_gateway.workshop_igw,
    aws_instance.web_server
  ]

  tags = {
    Name = "workshop-2-web-eip"
  }
}

# Gibt die oeffentliche IPv4-Adresse (Elastic IP) nach terraform apply im Terminal aus
output "instance_public_ip" {
  description = "Oeffentliche IPv4-Adresse der EC2-Instanz ueber die Elastic IP"
  value       = aws_eip.web_eip.public_ip
}
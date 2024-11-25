# Specify the required Terraform version and provider 
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"
}

# Configure the AWS provider
provider "aws" {
  region = "us-east-1"
}

# Data source to fetch the latest Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Create a VPC
resource "aws_vpc" "custom_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "CustomVPC"
  }
}

# Create an Internet Gateway
resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.custom_vpc.id

  tags = {
    Name = "InternetGateway"
  }
}

# Create a custom route table
resource "aws_route_table" "custom_route_table" {
  vpc_id = aws_vpc.custom_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gateway.id
  }

  tags = {
    Name = "CustomRouteTable"
  }
}

# Create a subnet
resource "aws_subnet" "custom_subnet" {
  vpc_id                  = aws_vpc.custom_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "CustomSubnet"
  }
}
# Create a second subnet in a different availability zone
resource "aws_subnet" "custom_subnet_2" {
  vpc_id                  = aws_vpc.custom_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "CustomSubnet2"
  }
}


# Associate the subnet with the route table
resource "aws_route_table_association" "subnet_route_association" {
  subnet_id      = aws_subnet.custom_subnet.id
  route_table_id = aws_route_table.custom_route_table.id
}

# Create a security group
resource "aws_security_group" "web_sg" {
  name        = "web_server_sg"
  description = "Allow HTTP inbound and all outbound"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  vpc_id = aws_vpc.custom_vpc.id
}

# Create a network interface for the first EC2 instance
resource "aws_network_interface" "web_network_interface" {
  subnet_id       = aws_subnet.custom_subnet.id
  private_ips     = ["10.0.1.10"]
  security_groups = [aws_security_group.web_sg.id]
}

# Create a network interface for the second EC2 instance
resource "aws_network_interface" "web_network_interface_2" {
  subnet_id       = aws_subnet.custom_subnet.id
  private_ips     = ["10.0.1.11"]
  security_groups = [aws_security_group.web_sg.id]
}

# Create an Elastic IP for the first EC2 instance
resource "aws_eip" "web_eip" {
  network_interface = aws_network_interface.web_network_interface.id

  depends_on = [aws_instance.web_server]
}

# Create an Elastic IP for the second EC2 instance
resource "aws_eip" "web_eip_2" {
  network_interface = aws_network_interface.web_network_interface_2.id

  depends_on = [aws_instance.web_server_2]
}

# Create the first EC2 instance
resource "aws_instance" "web_server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  network_interface {
    network_interface_id = aws_network_interface.web_network_interface.id
    device_index         = 0
  }

  user_data = <<-EOF
    #!/bin/bash
    sudo apt-get update
    sudo apt-get install -y apache2
    sudo systemctl start apache2
    sudo systemctl enable apache2
    echo "<h1>Hello World</h1>" | sudo tee /var/www/html/index.html
  EOF

  tags = {
    Name = "Terraform-Web-Server-1"
  }
}

# Create the second EC2 instance
resource "aws_instance" "web_server_2" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  network_interface {
    network_interface_id = aws_network_interface.web_network_interface_2.id
    device_index         = 0
  }

  user_data = <<-EOF
    #!/bin/bash
    sudo apt-get update
    sudo apt-get install -y apache2
    sudo systemctl start apache2
    sudo systemctl enable apache2
    echo "<h1>Hello World - Server 2</h1>" | sudo tee /var/www/html/index.html
  EOF

  tags = {
    Name = "Terraform-Web-Server-2"
  }
}

# Output the public IPs of both EC2 instances
output "public_ip" {
  value = aws_eip.web_eip.public_ip
}

output "public_ip_2" {
  value = aws_eip.web_eip_2.public_ip
}

# Create a target group
resource "aws_lb_target_group" "web_target_group" {
  name        = "web-target-group"
  protocol    = "HTTP"
  port        = 80
  vpc_id      = aws_vpc.custom_vpc.id
  target_type = "instance"

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name = "WebTargetGroup"
  }
}

# Create an application load balancer
resource "aws_lb" "web_load_balancer" {
  name               = "web-load-balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = [
    aws_subnet.custom_subnet.id,
    aws_subnet.custom_subnet_2.id
  ]

  tags = {
    Name = "WebLoadBalancer"
  }
}


# Create a listener for the load balancer
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.web_load_balancer.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_target_group.arn
  }
}

# Register EC2 instances with the target group
resource "aws_lb_target_group_attachment" "web_server_1_attachment" {
  target_group_arn = aws_lb_target_group.web_target_group.arn
  target_id        = aws_instance.web_server.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "web_server_2_attachment" {
  target_group_arn = aws_lb_target_group.web_target_group.arn
  target_id        = aws_instance.web_server_2.id
  port             = 80
}

# Output the DNS of the load balancer
output "load_balancer_dns" {
  value = aws_lb.web_load_balancer.dns_name
}

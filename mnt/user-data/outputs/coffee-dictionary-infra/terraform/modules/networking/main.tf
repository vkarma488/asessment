##############################################################################
# Networking Module
# Creates a VPC with public + private subnets across 3 AZs
# Public:  ALB, NAT Gateways
# Private: ECS tasks, EFS mount targets
##############################################################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "coffee-dictionary-vpc-${var.environment}" }
}

# Public subnets – one per AZ for the ALB
resource "aws_subnet" "public" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "coffee-dictionary-public-${var.availability_zones[count.index]}-${var.environment}" }
}

# Private subnets – one per AZ for ECS tasks
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "coffee-dictionary-private-${var.availability_zones[count.index]}-${var.environment}" }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "coffee-dictionary-igw-${var.environment}" }
}

# NAT Gateways – one per AZ so that private subnets can reach ECR/CloudWatch
# (reduce cross-AZ data transfer costs for small workloads consider single NAT)
resource "aws_eip" "nat" {
  count  = length(var.availability_zones)
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  count         = length(var.availability_zones)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.main]

  tags = { Name = "coffee-dictionary-nat-${var.availability_zones[count.index]}-${var.environment}" }
}

# Route tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "coffee-dictionary-public-rt-${var.environment}" }
}

resource "aws_route_table" "private" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }
  tags = { Name = "coffee-dictionary-private-rt-${var.availability_zones[count.index]}-${var.environment}" }
}

resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

##############################################################################
# Security Groups
##############################################################################

# ALB – accepts HTTPS from internet
resource "aws_security_group" "alb" {
  name        = "coffee-dictionary-alb-${var.environment}"
  description = "ALB – allow HTTPS inbound from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
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
}

# ECS tasks – only accept traffic from ALB
resource "aws_security_group" "ecs_tasks" {
  name        = "coffee-dictionary-ecs-${var.environment}"
  description = "ECS tasks – allow traffic from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EFS – allow NFS from ECS tasks
resource "aws_security_group" "efs" {
  name        = "coffee-dictionary-efs-${var.environment}"
  description = "EFS – allow NFS from ECS tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }
}

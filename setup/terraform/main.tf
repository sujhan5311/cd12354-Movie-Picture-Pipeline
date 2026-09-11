####################
# VPC Configuration
####################
resource "aws_vpc" "vpc" {
  tags = { "Name" = "udacity" }
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1${var.public_az}"
  map_public_ip_on_launch = true
  tags = { Name = "udacity-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.vpc.id
  availability_zone = "us-east-1${var.private_az}"
  cidr_block        = "10.0.2.0/24"
  tags = { Name = "udacity-private" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.vpc.id
  tags = { Name = "private" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "eks" {
  count               = var.enable_private == true ? 1 : 0
  vpc_id              = aws_vpc.vpc.id
  service_name        = "com.amazonaws.us-east-1.eks"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_eks_cluster.main.vpc_config.0.cluster_security_group_id]
  subnet_ids          = [aws_subnet.private_subnet.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ec2" {
  count               = var.enable_private == true ? 1 : 0
  vpc_id              = aws_vpc.vpc.id
  service_name        = "com.amazonaws.us-east-1.ec2"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_eks_cluster.main.vpc_config.0.cluster_security_group_id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ecr-dkr-endpoint" {
  count               = var.enable_private == true ? 1 : 0
  vpc_id              = aws_vpc.vpc.id
  service_name        = "com.amazonaws.us-east-1.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_eks_cluster.main.vpc_config.0.cluster_security_group_id]
  subnet_ids          = [aws_subnet.private_subnet.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ecr-api-endpoint" {
  count               = var.enable_private == true ? 1 : 0
  vpc_id              = aws_vpc.vpc.id
  service_name        = "com.amazonaws.us-east-1.ecr.api"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_eks_cluster.main.vpc_config.0.cluster_security_group_id]
  subnet_ids          = [aws_subnet.private_subnet.id]
  private_dns_enabled = true
}

###################
# ECR Repositories
###################
resource "aws_ecr_repository" "frontend" {
  name                 = "frontend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_repository" "backend" {
  name                 = "backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}

################
# EKS Resources
################
resource "aws_eks_cluster" "main" {
  name     = "cluster"
  role_arn = aws_iam_role.eks_cluster.arn
  vpc_config {
    subnet_ids              = [aws_subnet.private_subnet.id, aws_subnet.public_subnet.id]
    endpoint_public_access  = var.enable_private == true ? false : true
    endpoint_private_access = true
  }
  depends_on = [aws_iam_role_policy_attachment.eks_cluster, aws_iam_role_policy_attachment.eks_service]
}

resource "aws_iam_role" "eks_cluster" {
  name = "eks_cluster_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "eks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_service" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.eks_cluster.name
}

##################
# EKS Node Group
##################
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "udacity"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = [aws_subnet.public_subnet.id]
  instance_types  = ["t3.medium"]
  ami_type        = "BOTTLEROCKET_x86_64"

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_group_policy,
    aws_iam_role_policy_attachment.cni_policy,
    aws_iam_role_policy_attachment.ecr_policy,
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

resource "aws_iam_role" "node_group" {
  name               = "udacity-node-group"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

resource "aws_iam_role_policy_attachment" "node_group_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cni_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

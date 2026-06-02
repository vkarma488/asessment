##############################################################################
# Lost Alley Coffee Syndicate – Coffee Dictionary API
# Production Environment – AWS ap-southeast-2 (Sydney)
#
# Architecture:
#   Route 53 → CloudFront → ALB → ECS Fargate (ap-southeast-2a/b/c)
#   ECR (container registry) | CloudWatch (logs/metrics/alarms)
#   Secrets Manager | WAF | S3 (future flat-file migration path)
##############################################################################

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state – use S3 + DynamoDB for team collaboration and locking
  backend "s3" {
    bucket         = "coffee-syndicate-tfstate"
    key            = "production/coffee-dictionary/terraform.tfstate"
    region         = "ap-southeast-2"
    encrypt        = true
    dynamodb_table = "coffee-syndicate-tfstate-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "coffee-dictionary"
      Environment = "production"
      ManagedBy   = "terraform"
      Owner       = "lost-alley-coffee-syndicate"
    }
  }
}

# us-east-1 provider required for CloudFront WAF (WAFv2 must be in us-east-1)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

##############################################################################
# Networking
##############################################################################

module "networking" {
  source = "../../modules/networking"

  vpc_cidr             = var.vpc_cidr
  availability_zones   = ["ap-southeast-2a", "ap-southeast-2b", "ap-southeast-2c"]
  environment          = var.environment
}

##############################################################################
# ECR – Container Registry
##############################################################################

module "ecr" {
  source = "../../modules/ecr"

  repository_name     = "coffee-dictionary"
  environment         = var.environment
  # Keep last 10 tagged images; expire untagged after 7 days
  image_tag_mutability = "IMMUTABLE"
}

##############################################################################
# IAM
##############################################################################

module "iam" {
  source = "../../modules/iam"

  environment    = var.environment
  aws_region     = var.aws_region
  aws_account_id = data.aws_caller_identity.current.account_id
}

##############################################################################
# Application Load Balancer
##############################################################################

module "alb" {
  source = "../../modules/alb"

  vpc_id          = module.networking.vpc_id
  public_subnets  = module.networking.public_subnet_ids
  environment     = var.environment
  certificate_arn = var.acm_certificate_arn
}

##############################################################################
# ECS Fargate Cluster + Service
##############################################################################

module "ecs" {
  source = "../../modules/ecs"

  vpc_id              = module.networking.vpc_id
  private_subnets     = module.networking.private_subnet_ids
  alb_target_group_arn = module.alb.target_group_arn
  alb_security_group_id = module.alb.security_group_id

  ecr_repository_url  = module.ecr.repository_url
  image_tag           = var.image_tag

  execution_role_arn  = module.iam.ecs_execution_role_arn
  task_role_arn       = module.iam.ecs_task_role_arn

  environment         = var.environment
  aws_region          = var.aws_region

  # Sizing – start small, let auto-scaling handle growth
  task_cpu            = 256   # 0.25 vCPU
  task_memory         = 512   # 512 MB
  desired_count       = 2     # minimum 2 for HA across AZs

  # Auto-scaling bounds
  min_capacity        = 2
  max_capacity        = 10

  # Flat-file DB path inside container (EFS mount)
  efs_file_system_id  = aws_efs_file_system.data.id
  efs_access_point_id = aws_efs_access_point.data.id
}

##############################################################################
# EFS – Persistent storage for the flat-file database
#
# NOTE: This keeps the existing flat-file approach working immediately.
# See docs/scaling-data.md for the migration path to RDS/DynamoDB.
##############################################################################

resource "aws_efs_file_system" "data" {
  creation_token = "coffee-dictionary-data-${var.environment}"
  encrypted      = true

  # Automatically move cold data to cheaper Infrequent Access tier
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name = "coffee-dictionary-data-${var.environment}"
  }
}

resource "aws_efs_access_point" "data" {
  file_system_id = aws_efs_file_system.data.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/data"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "755"
    }
  }
}

# Mount EFS in each private subnet
resource "aws_efs_mount_target" "data" {
  for_each = toset(module.networking.private_subnet_ids)

  file_system_id  = aws_efs_file_system.data.id
  subnet_id       = each.value
  security_groups = [module.networking.efs_security_group_id]
}

##############################################################################
# CloudFront Distribution (CDN + edge caching for AU users)
##############################################################################

resource "aws_cloudfront_distribution" "api" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "coffee-dictionary API – ${var.environment}"
  price_class     = "PriceClass_All" # Use AU edge nodes

  # WAF – associate the WebACL created in us-east-1
  web_acl_id = aws_wafv2_web_acl.api.arn

  origin {
    domain_name = module.alb.dns_name
    origin_id   = "alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "alb-origin"

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Content-Type", "Accept"]
      cookies { forward = "none" }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0    # API responses – no caching by default
    max_ttl                = 86400
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none" # Restrict to AU via WAF rules if needed
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.cloudfront_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

##############################################################################
# WAF – Basic rate limiting + AWS managed rules
##############################################################################

resource "aws_wafv2_web_acl" "api" {
  provider = aws.us_east_1
  name     = "coffee-dictionary-${var.environment}"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # AWS Managed Core Rule Set
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rate limiting – 1000 req/5min per IP
  rule {
    name     = "RateLimitRule"
    priority = 2
    action { block {} }
    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitRuleMetric"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "coffee-dictionary-waf-${var.environment}"
    sampled_requests_enabled   = true
  }
}

##############################################################################
# Data sources
##############################################################################

data "aws_caller_identity" "current" {}

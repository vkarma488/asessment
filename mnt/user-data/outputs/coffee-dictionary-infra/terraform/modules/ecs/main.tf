##############################################################################
# ECS Module – Fargate cluster, task definition, service, auto-scaling
##############################################################################

resource "aws_ecs_cluster" "main" {
  name = "coffee-dictionary-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"  # CloudWatch Container Insights for metrics
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 2           # Always keep 2 on regular Fargate (HA guarantee)
    weight            = 1
    capacity_provider = "FARGATE"
  }
  # Use FARGATE_SPOT for scale-out tasks – ~70% cheaper
  default_capacity_provider_strategy {
    base              = 0
    weight            = 4
    capacity_provider = "FARGATE_SPOT"
  }
}

##############################################################################
# CloudWatch Log Group
##############################################################################

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/coffee-dictionary-${var.environment}"
  retention_in_days = 30
}

##############################################################################
# Task Definition
##############################################################################

resource "aws_ecs_task_definition" "app" {
  family                   = "coffee-dictionary-${var.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  # EFS volume for flat-file database persistence
  volume {
    name = "coffee-data"
    efs_volume_configuration {
      file_system_id          = var.efs_file_system_id
      transit_encryption      = "ENABLED"
      transit_encryption_port = 2999
      authorization_config {
        access_point_id = var.efs_access_point_id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "coffee-dictionary"
      image     = "${var.ecr_repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = 3000
          protocol      = "tcp"
        }
      ]

      mountPoints = [
        {
          sourceVolume  = "coffee-data"
          containerPath = "/usr/src/app/data"
          readOnly      = false
        }
      ]

      environment = [
        { name = "NODE_ENV",  value = "production" },
        { name = "PORT",      value = "3000" },
        { name = "DATA_PATH", value = "/usr/src/app/data" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      # Health check – Express has a /health endpoint (or root works)
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:3000/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }

      # Resource limits to prevent a runaway container exhausting the task
      ulimits = [
        { name = "nofile", softLimit = 65536, hardLimit = 65536 }
      ]
    }
  ])
}

##############################################################################
# ECS Service
##############################################################################

resource "aws_ecs_service" "app" {
  name                               = "coffee-dictionary-${var.environment}"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.app.arn
  desired_count                      = var.desired_count
  health_check_grace_period_seconds  = 30

  # Rolling deployment – zero downtime
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true   # Auto-rollback on failed deployment
  }

  network_configuration {
    subnets          = var.private_subnets
    security_groups  = [var.ecs_security_group_id]
    assign_public_ip = false  # Tasks live in private subnets
  }

  load_balancer {
    target_group_arn = var.alb_target_group_arn
    container_name   = "coffee-dictionary"
    container_port   = 3000
  }

  # Force a new deployment when image_tag changes (enables GitOps-style deploys)
  force_new_deployment = true

  lifecycle {
    ignore_changes = [desired_count]  # Let auto-scaling manage this
  }
}

##############################################################################
# Auto Scaling
##############################################################################

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Scale out when CPU > 60%
resource "aws_appautoscaling_policy" "cpu_scale_out" {
  name               = "coffee-dictionary-cpu-scale-out-${var.environment}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# Scale out when memory > 70%
resource "aws_appautoscaling_policy" "memory_scale_out" {
  name               = "coffee-dictionary-memory-scale-out-${var.environment}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

##############################################################################
# CloudWatch Alarms
##############################################################################

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "coffee-dictionary-high-cpu-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ECS CPU utilisation exceeded 80%"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.app.name
  }
}

resource "aws_cloudwatch_metric_alarm" "task_count_low" {
  alarm_name          = "coffee-dictionary-task-count-low-${var.environment}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = var.min_capacity
  alarm_description   = "Running task count dropped below minimum – possible crash loop"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.app.name
  }
}

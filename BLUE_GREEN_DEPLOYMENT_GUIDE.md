# ECS Blue/Green 배포 구현 가이드

## 개요
ECS Blue/Green 배포를 위해서는 다음 컴포넌트들이 필요합니다:
- 2개의 Target Group (Blue, Green)
- CodeDeploy Application 및 Deployment Group
- 적절한 IAM 역할
- AppSpec 파일

## 현재 모듈 수정 필요사항

### 1. ecs-service 모듈 수정

#### variables.tf 추가
```hcl
variable "deployment_controller_type" {
  description = "ECS deployment controller type (ECS or CODE_DEPLOY)"
  type        = string
  default     = "ECS"

  validation {
    condition     = contains(["ECS", "CODE_DEPLOY"], var.deployment_controller_type)
    error_message = "Deployment controller must be ECS or CODE_DEPLOY."
  }
}

variable "enable_blue_green" {
  description = "Enable Blue/Green deployment (creates additional target group)"
  type        = bool
  default     = false
}

variable "blue_green_config" {
  description = "Blue/Green deployment configuration"
  type = object({
    prod_traffic_listener_arn  = string  # Production 트래픽 리스너
    test_traffic_listener_arn  = string  # Test 트래픽 리스너 (optional)
    termination_wait_minutes   = number  # Blue 환경 종료 대기 시간
  })
  default = {
    prod_traffic_listener_arn  = ""
    test_traffic_listener_arn  = ""
    termination_wait_minutes   = 5
  }
}
```

#### alb.tf 수정
```hcl
# Blue Target Group (기존)
resource "aws_lb_target_group" "this" {
  count = var.create_load_balancer || var.load_balancer_arn != "" ? 1 : 0

  name        = local.target_group_name
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # ... 기존 설정 ...

  tags = merge(
    local.common_tags,
    {
      Name = local.target_group_name
      Type = "Blue"
    }
  )
}

# Green Target Group (Blue/Green 배포용)
resource "aws_lb_target_group" "green" {
  count = var.enable_blue_green ? 1 : 0

  name        = "${local.target_group_name}-green"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # Blue와 동일한 설정
  deregistration_delay              = var.deregistration_delay
  load_balancing_algorithm_type     = "round_robin"

  health_check {
    enabled             = var.health_check.enabled
    healthy_threshold   = var.health_check.healthy_threshold
    interval            = var.health_check.interval
    matcher             = var.health_check.matcher
    path                = var.health_check.path
    port                = var.health_check.port
    protocol            = var.health_check.protocol
    timeout             = var.health_check.timeout
    unhealthy_threshold = var.health_check.unhealthy_threshold
  }

  stickiness {
    enabled         = var.stickiness.enabled
    type           = var.stickiness.type
    cookie_duration = var.stickiness.cookie_duration
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.target_group_name}-green"
      Type = "Green"
    }
  )
}

# Test Listener (8443 포트 - Blue/Green 테스트용)
resource "aws_lb_listener" "test" {
  count = var.enable_blue_green && var.create_load_balancer ? 1 : 0

  load_balancer_arn = local.load_balancer_arn
  port              = 8443
  protocol          = "HTTPS"
  ssl_policy        = var.listener_ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[0].arn
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.alb_name}-test-listener"
      Type = "Test"
    }
  )
}
```

#### ecs.tf 수정
```hcl
resource "aws_ecs_service" "this" {
  name    = local.service_name
  cluster = var.cluster_arn

  # ... 기존 설정 ...

  # Deployment Controller 설정
  deployment_controller {
    type = var.deployment_controller_type
  }

  # Load Balancer 설정 (CODE_DEPLOY 모드에서는 설정하지 않음)
  dynamic "load_balancer" {
    for_each = var.deployment_controller_type == "ECS" && (var.create_load_balancer || var.load_balancer_arn != "") ? [1] : []

    content {
      target_group_arn = aws_lb_target_group.this[0].arn
      container_name   = local.container_name
      container_port   = var.container_port
    }
  }

  # ... 나머지 설정 ...

  lifecycle {
    ignore_changes = [
      load_balancer,  # CodeDeploy가 관리
      task_definition, # CodeDeploy가 관리
      desired_count,   # Auto Scaling이 관리할 수 있음
      network_configuration # CodeDeploy가 관리
    ]
  }
}
```

#### codedeploy.tf (새 파일)
```hcl
# CodeDeploy Application
resource "aws_codedeploy_app" "this" {
  count = var.enable_blue_green ? 1 : 0

  compute_platform = "ECS"
  name            = "${local.service_name}-deploy-app"

  tags = local.common_tags
}

# CodeDeploy Deployment Group
resource "aws_codedeploy_deployment_group" "this" {
  count = var.enable_blue_green ? 1 : 0

  app_name               = aws_codedeploy_app.this[0].name
  deployment_group_name  = "${local.service_name}-deploy-group"
  service_role_arn      = aws_iam_role.codedeploy[0].arn
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  blue_green_deployment_config {
    terminate_blue_instances_on_deployment_success {
      action                                          = "TERMINATE"
      termination_wait_time_in_minutes              = var.blue_green_config.termination_wait_minutes
    }

    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    green_fleet_provisioning_option {
      action = "COPY_AUTO_SCALING_GROUP"
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = local.cluster_name
    service_name = aws_ecs_service.this.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [local.listener_arn]
      }

      # Test traffic listener (optional)
      dynamic "test_traffic_route" {
        for_each = aws_lb_listener.test[*].arn

        content {
          listener_arns = [test_traffic_route.value]
        }
      }

      target_group {
        name = aws_lb_target_group.this[0].name
      }

      target_group {
        name = aws_lb_target_group.green[0].name
      }
    }
  }

  tags = local.common_tags
}

# CodeDeploy IAM Role
resource "aws_iam_role" "codedeploy" {
  count = var.enable_blue_green ? 1 : 0

  name = "${local.service_name}-codedeploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codedeploy.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "codedeploy" {
  count = var.enable_blue_green ? 1 : 0

  role       = aws_iam_role.codedeploy[0].name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}
```

#### outputs.tf 추가
```hcl
output "codedeploy" {
  description = "CodeDeploy related outputs"
  value = var.enable_blue_green ? {
    app_name              = aws_codedeploy_app.this[0].name
    deployment_group_name = aws_codedeploy_deployment_group.this[0].deployment_group_name
    blue_target_group_arn = aws_lb_target_group.this[0].arn
    green_target_group_arn = aws_lb_target_group.green[0].arn
    test_listener_arn     = try(aws_lb_listener.test[0].arn, null)
  } : null
}
```

### 2. pipeline 모듈 수정

pipeline 모듈은 이미 `blue_green_config`를 지원하므로, 다음과 같이 사용:

```hcl
module "pipeline" {
  source = "../../module/pipeline"

  # ... 기존 설정 ...

  blue_green_config = {
    enabled              = true
    app_spec_file       = "appspec.yml"
    codedeploy_app      = module.ecs_service.codedeploy.app_name
    deployment_group    = module.ecs_service.codedeploy.deployment_group_name
    task_definition_file = "taskdef.json"
  }
}
```

## 서비스에서 사용 예시

```hcl
# Blue/Green 배포를 사용하는 서비스
module "app_with_blue_green" {
  source = "../../module/ecs-service"

  # 기본 설정
  application_name = "my-app"
  project         = "com"
  environment     = "dev"

  # Blue/Green 배포 활성화
  deployment_controller_type = "CODE_DEPLOY"
  enable_blue_green         = true

  blue_green_config = {
    prod_traffic_listener_arn  = module.app.networking.listener_arn
    test_traffic_listener_arn  = ""  # 테스트 리스너는 모듈이 자동 생성
    termination_wait_minutes   = 5
  }

  # ... 나머지 설정 ...
}

# Pipeline 설정
module "app_pipeline" {
  source = "../../module/pipeline"

  # ... 기본 설정 ...

  blue_green_config = {
    enabled              = true
    app_spec_file       = "appspec.yml"
    codedeploy_app      = module.app_with_blue_green.codedeploy.app_name
    deployment_group    = module.app_with_blue_green.codedeploy.deployment_group_name
    task_definition_file = "taskdef.json"
  }
}
```

## AppSpec.yml 템플릿

```yaml
version: 0.0
Resources:
  - TargetService:
      Type: AWS::ECS::Service
      Properties:
        TaskDefinition: <TASK_DEFINITION>
        LoadBalancerInfo:
          ContainerName: "CONTAINER_NAME_PLACEHOLDER"
          ContainerPort: CONTAINER_PORT_PLACEHOLDER
        PlatformVersion: "LATEST"
        NetworkConfiguration:
          AwsVpcConfiguration:
            Subnets:
              - "SUBNET_1_PLACEHOLDER"
              - "SUBNET_2_PLACEHOLDER"
            SecurityGroups:
              - "SECURITY_GROUP_PLACEHOLDER"
            AssignPublicIp: "DISABLED"

# Hooks는 선택사항
Hooks:
  - BeforeInstall: "arn:aws:lambda:REGION:ACCOUNT:function:FUNCTION_NAME"
  - AfterInstall: "arn:aws:lambda:REGION:ACCOUNT:function:FUNCTION_NAME"
  - AfterAllowTestTraffic: "arn:aws:lambda:REGION:ACCOUNT:function:FUNCTION_NAME"
  - BeforeAllowTraffic: "arn:aws:lambda:REGION:ACCOUNT:function:FUNCTION_NAME"
  - AfterAllowTraffic: "arn:aws:lambda:REGION:ACCOUNT:function:FUNCTION_NAME"
```

## 주의사항

1. **Target Group 2개 필요**: Blue와 Green 각각의 Target Group
2. **Listener 2개 권장**: Production(443)과 Test(8443) 트래픽 분리
3. **CodeDeploy 권한**: ECS 서비스 업데이트 권한 필요
4. **초기 배포**: Blue/Green 설정 전 일반 ECS 배포로 초기 서비스 생성 필요
5. **비용**: 배포 중 일시적으로 2배의 태스크 실행 (Blue + Green)

## 구현 순서

1. ecs-service 모듈에 Blue/Green 지원 코드 추가
2. 기존 서비스를 일반 ECS 모드로 먼저 배포
3. Blue/Green 모드로 전환 (deployment_controller_type 변경)
4. Pipeline에 blue_green_config 설정 추가
5. appspec.yml 파일을 소스 코드에 추가
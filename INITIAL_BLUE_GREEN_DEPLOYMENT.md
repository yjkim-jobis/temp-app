# 초기 Blue/Green 배포 가이드

## 개요
CODE_DEPLOY 컨트롤러를 사용하는 ECS 서비스는 초기 생성 시 특별한 처리가 필요합니다.

## 초기 배포 프로세스

### 1단계: 인프라 생성
```bash
cd services/com-scraping-worker
terraform init
terraform apply
```

이 단계에서 생성되는 리소스:
- ECS Service (CODE_DEPLOY 컨트롤러)
- ALB + 2개의 Target Group (Blue/Green)
- Test Listener (8443 포트)
- CodeDeploy Application & Deployment Group
- CodePipeline

### 2단계: 초기 태스크 수동 등록 (중요!)
CODE_DEPLOY 컨트롤러를 사용하면 초기에 타겟 그룹에 태스크가 등록되지 않습니다.
첫 번째 배포를 트리거해야 합니다:

```bash
# 방법 1: Pipeline 수동 실행
aws codepipeline start-pipeline-execution \
  --name com-apne2-scraping-worker-pipeline-dev

# 방법 2: 더미 태스크 정의 업데이트
aws ecs update-service \
  --cluster com-apne2-ecs-cluster-dev \
  --service com-apne2-scraping-worker-ecs-dev \
  --force-new-deployment
```

### 3단계: appspec.yml 파일 준비
소스 코드 레포지토리의 루트에 `appspec.yml` 파일 추가:

```yaml
version: 0.0
Resources:
  - TargetService:
      Type: AWS::ECS::Service
      Properties:
        TaskDefinition: <TASK_DEFINITION>
        LoadBalancerInfo:
          ContainerName: "com-apne2-scraping-worker-container-dev"
          ContainerPort: 8080
        PlatformVersion: "LATEST"
        NetworkConfiguration:
          AwsVpcConfiguration:
            Subnets:
              - "subnet-0b107f25c46759aea"
              - "subnet-0203415ae3e901deb"
            SecurityGroups:
              - "<WILL_BE_REPLACED_BY_TERRAFORM>"
            AssignPublicIp: "DISABLED"
```

## 장점과 단점

### 장점
✅ 처음부터 Blue/Green 배포 가능
✅ 배포 실패 시 빠른 롤백
✅ Test 트래픽으로 검증 가능
✅ 학습 비용 없이 일관된 배포 방식

### 단점
⚠️ 초기 설정이 복잡
⚠️ 첫 배포는 수동으로 트리거 필요
⚠️ 리소스가 더 많이 생성됨 (2개 Target Group)

## 대안: 단계적 접근

만약 초기 복잡성을 피하고 싶다면:

```hcl
# STEP 1: Rolling Update로 시작
deployment_controller_type = "ECS"  # 기본값
enable_blue_green = false

# STEP 2: 서비스 안정화 후 Blue/Green 전환
# 1. 서비스 삭제
# 2. deployment_controller_type = "CODE_DEPLOY"로 변경
# 3. 서비스 재생성
```

## 권장사항

- **신규 서비스**: 처음부터 Blue/Green 설정 권장 (학습 비용 절감)
- **기존 서비스 마이그레이션**: Rolling Update 유지
- **중요 서비스**: Blue/Green 적용 (빠른 롤백 필요)
- **개발/테스트**: Rolling Update로 충분
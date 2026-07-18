# ecs-deploy-pipeline

CI/CD pipeline with GitHub Actions and Terraform for blue/green deployments on AWS ECS.

## Architecture

```
 push to main
      │
      ▼
┌─────────────────────── GitHub Actions ───────────────────────┐
│ test (mvn verify) ─▶ build image ─▶ push ECR ─▶ register     │
│                                       (OIDC)    taskdef ─▶   │
│                                              CodeDeploy      │
└──────────────────────────────────────────────┬───────────────┘
                                               ▼
                          ┌──────────── AWS CodeDeploy ────────┐
                          │  blue/green with traffic control   │
                          └──────┬─────────────────┬───────────┘
                                 ▼                 ▼
       ALB :80 (prod) ──▶ [ blue tasks ]    [ green tasks ] ◀── ALB :9001 (test)
                          ECS Fargate service, 2 target groups
```

Each deploy: CodeDeploy launches the new revision as the **green** task set, health-checks it behind the test listener, shifts production traffic, then terminates blue after 5 minutes. Failures roll back automatically.

## Stack

- **Terraform** (`terraform/`): VPC, ALB with blue/green target groups + prod/test listeners, ECS Fargate cluster/service (`CODE_DEPLOY` deployment controller), ECR, CodeDeploy app + deployment group, IAM (task execution, CodeDeploy service role, GitHub OIDC deploy role — no static AWS keys in CI).
- **GitHub Actions** (`.github/workflows/deploy.yml`): test on PRs and pushes; on `main`, build/push image tagged with the commit SHA (immutable tags), render `deploy/taskdef.json`, register the revision and trigger the CodeDeploy blue/green deployment, waiting for stability.
- **App** (`app/`): minimal Spring Boot service; `/` returns the deployed version (`APP_VERSION` = commit SHA), `/actuator/health` backs ALB health checks.

## Run locally — no AWS account needed

The full blue/green flow can be exercised locally. nginx plays the ALB, two containers play the blue/green task sets, and `deploy/local-deploy.sh` plays CodeDeploy:

| AWS | Local equivalent |
|---|---|
| ALB prod listener :80 | nginx `:8081` |
| ALB test listener :9001 | nginx `:9001` |
| Blue / green target groups + ECS task sets | `ecsdemo-app-blue` / `ecsdemo-app-green` containers |
| CodeDeploy deployment | `./deploy/local-deploy.sh <version>` |
| Auto rollback / redeploy previous | `./deploy/local-deploy.sh rollback` |

```bash
./deploy/local-deploy.sh v1        # first run: builds and boots the whole environment
curl localhost:8081/               # prod -> v1

./deploy/local-deploy.sh v2        # deploys v2 to the inactive color:
                                   #   1. build image  2. start inactive color
                                   #   3. health check via test listener :9001
                                   #   4. shift prod traffic  5. keep old color for rollback
curl localhost:8081/               # prod -> v2
curl localhost:9001/               # test listener -> previous color

./deploy/local-deploy.sh status    # active color + versions
./deploy/local-deploy.sh rollback  # instant traffic shift back

docker compose down                # tear down
```

If the new version fails its health check, production traffic is never touched — same guarantee CodeDeploy gives.

## Deploy to AWS — bootstrap (one-time)

```bash
cd terraform
terraform init
terraform apply -var github_repository="<owner>/<repo>"
```

Push a bootstrap image so the first ECS task can start (the CI pipeline replaces it on the first deploy):

```bash
ECR_URL=$(terraform output -raw ecr_repository_url)
aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR_URL%%/*}"
docker build -t "$ECR_URL:bootstrap" ../app
docker push "$ECR_URL:bootstrap"
```

Configure GitHub:

1. Repository secret `AWS_DEPLOY_ROLE_ARN` = `terraform output -raw github_deploy_role_arn`.
2. If `project_name`/region differ from defaults, adjust the `env` block in `.github/workflows/deploy.yml` and `deploy/taskdef.json`.

## Deploy

Push to `main`. Watch the run in Actions, or:

```bash
aws deploy list-deployments --application-name ecs-bluegreen-demo
curl "$(terraform -chdir=terraform output -raw alb_dns_name)"   # shows deployed version
```

During deployment, the new revision can be validated on the test listener (`:9001`) before/while traffic shifts. To require manual approval before shifting, change `deployment_ready_option` in `terraform/codedeploy.tf` to `STOP_DEPLOYMENT`.

## Rollback

- Automatic on deployment failure (`auto_rollback_configuration`).
- Manual: `aws deploy stop-deployment --deployment-id <id> --auto-rollback-enabled`, or redeploy a previous commit SHA.

## Costs

Demo runs on public subnets without NAT gateway to stay cheap; still creates an ALB and Fargate tasks (not free tier). Destroy when done:

```bash
terraform -chdir=terraform destroy
```

## Layout

```
app/                      # Spring Boot demo service + Dockerfile
deploy/appspec.yaml       # CodeDeploy ECS appspec
deploy/taskdef.json       # task definition template rendered by CI
deploy/local-deploy.sh    # local blue/green deploy (CodeDeploy simulation)
docker-compose.yml        # local environment: nginx "ALB" + blue/green containers
local/nginx/              # nginx config template rendered per deploy
terraform/                # full IaC for the AWS environment
.github/workflows/        # build/test/push/deploy pipeline
```

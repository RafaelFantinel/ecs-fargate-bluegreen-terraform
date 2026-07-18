# ecs-deploy-pipeline

CI/CD pipeline with GitHub Actions and Terraform for **blue/green deployments on AWS ECS Fargate**, orchestrated by CodeDeploy — plus a fully local simulation of the same flow that requires no AWS account.

## Table of contents

- [Architecture](#architecture)
- [How a deploy works](#how-a-deploy-works)
- [Stack](#stack)
- [Application endpoints](#application-endpoints)
- [Run locally — no AWS account needed](#run-locally--no-aws-account-needed)
- [Deploy to AWS](#deploy-to-aws)
- [Terraform variables](#terraform-variables)
- [Rollback](#rollback)
- [Security notes](#security-notes)
- [Costs](#costs)
- [Repository layout](#repository-layout)
- [Troubleshooting](#troubleshooting)

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

## How a deploy works

On every push to `main`:

1. **Test** — `mvn verify` runs on every PR and push; the deploy job only starts if tests pass.
2. **Build & push** — the Docker image is built and pushed to ECR tagged with the commit SHA (immutable tags, one image per commit).
3. **Register task definition** — `deploy/taskdef.json` is rendered with the account ID, region and version, and registered as a new revision.
4. **Blue/green shift** — CodeDeploy launches the new revision as the **green** task set, registers it in the green target group, and health-checks it behind the test listener (`:9001`).
5. **Traffic switch** — once green is healthy, production traffic (`:80`) shifts to it. The old (blue) task set is kept for 5 minutes, then terminated.
6. **Rollback on failure** — if the deployment fails at any point, CodeDeploy rolls back automatically and production traffic is never disrupted.

The GitHub Actions job waits for service stability (`wait-for-service-stability: true`), so a red workflow run means the deploy genuinely failed and was rolled back.

## Stack

| Component | Location | Role |
|---|---|---|
| Terraform | `terraform/` | VPC, ALB (blue/green target groups + prod/test listeners), ECS Fargate cluster/service with `CODE_DEPLOY` deployment controller, ECR, CodeDeploy app + deployment group, CloudWatch logs, IAM |
| GitHub Actions | `.github/workflows/deploy.yml` | Test on PRs/pushes; build, push and blue/green deploy on `main` |
| CodeDeploy config | `deploy/appspec.yaml`, `deploy/taskdef.json` | ECS appspec + task definition template rendered by CI |
| App | `app/` | Minimal Spring Boot 3 / Java 21 service used as the deploy target |
| Local simulation | `docker-compose.yml`, `local/`, `deploy/local-deploy.sh` | Full blue/green flow without AWS |

IAM is intentionally split into three roles (`terraform/iam.tf`):

- **Task execution role** — pulls from ECR, writes CloudWatch logs.
- **CodeDeploy service role** — orchestrates task sets and traffic shifting.
- **GitHub OIDC deploy role** — assumed by the workflow via OIDC federation, scoped to this repository. **No static AWS keys exist anywhere in CI.**

## Application endpoints

| Endpoint | Purpose |
|---|---|
| `GET /` | Returns service name and deployed version (`APP_VERSION` = commit SHA) — makes blue/green switchover visible |
| `GET /actuator/health` | Backs ALB health checks and the local health gate |

```json
{ "service": "ecs-demo-app", "version": "<commit-sha>", "message": "Deployed via blue/green on ECS" }
```

## Run locally — no AWS account needed

The full blue/green flow can be exercised locally. nginx plays the ALB, two containers play the blue/green task sets, and `deploy/local-deploy.sh` plays CodeDeploy:

| AWS | Local equivalent |
|---|---|
| ALB prod listener :80 | nginx `:8081` |
| ALB test listener :9001 | nginx `:9001` |
| Blue / green target groups + ECS task sets | `ecsdemo-app-blue` / `ecsdemo-app-green` containers |
| CodeDeploy deployment | `./deploy/local-deploy.sh <version>` |
| Auto rollback / redeploy previous | `./deploy/local-deploy.sh rollback` |

Requirements: Docker with the compose plugin, `curl`, bash.

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

Called with no version argument, the script uses the current git short SHA. Deploy state (active color + image tags) lives in `local/state.env`; the nginx config is re-rendered from `local/nginx/default.conf.template` on every traffic shift.

If the new version fails its health check, production traffic is never touched — same guarantee CodeDeploy gives.

## Deploy to AWS

### 1. Provision the infrastructure (one-time)

Requirements: Terraform ≥ 1.5, AWS CLI with credentials able to create the resources.

```bash
cd terraform
terraform init
terraform apply -var github_repository="<owner>/<repo>"
```

(Or copy `example.tfvars` and use `-var-file`.)

### 2. Push a bootstrap image (one-time)

The ECS service references a `:bootstrap` tag so the first task can start; the CI pipeline replaces it on the first real deploy:

```bash
ECR_URL=$(terraform output -raw ecr_repository_url)
aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR_URL%%/*}"
docker build -t "$ECR_URL:bootstrap" ../app
docker push "$ECR_URL:bootstrap"
```

### 3. Configure GitHub (one-time)

1. Repository secret `AWS_DEPLOY_ROLE_ARN` = `terraform output -raw github_deploy_role_arn`.
2. If `project_name`/region differ from the defaults, adjust the `env` block in `.github/workflows/deploy.yml` and the hardcoded names in `deploy/taskdef.json`.
3. Optional: protect the `production` environment in GitHub settings to require reviewer approval before the deploy job runs.

### 4. Deploy

Push to `main`. Watch the run in Actions, or:

```bash
aws deploy list-deployments --application-name ecs-bluegreen-demo
curl "$(terraform -chdir=terraform output -raw alb_dns_name)"        # deployed version
curl "$(terraform -chdir=terraform output -raw alb_test_url)"        # green, during a deploy
```

During deployment, the new revision can be validated on the test listener (`:9001`) before/while traffic shifts. To require manual approval before shifting, change `deployment_ready_option` in `terraform/codedeploy.tf` to `STOP_DEPLOYMENT` with a `wait_time_in_minutes`.

## Terraform variables

| Variable | Default | Description |
|---|---|---|
| `github_repository` | — (required) | `owner/repo` allowed to assume the deploy role via OIDC |
| `aws_region` | `us-east-1` | AWS region |
| `project_name` | `ecs-bluegreen-demo` | Name prefix for all resources |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR block |
| `container_port` | `8080` | Port the app container listens on |
| `desired_count` | `2` | Number of ECS tasks |
| `task_cpu` / `task_memory` | `256` / `512` | Fargate task size |
| `health_check_path` | `/actuator/health` | ALB health check path |

Key outputs: `alb_dns_name`, `alb_test_url`, `ecr_repository_url`, `github_deploy_role_arn` (full list in `terraform/outputs.tf`).

## Rollback

- **Automatic** — on deployment failure (`auto_rollback_configuration`), CodeDeploy shifts traffic back to blue.
- **Manual, mid-deploy** — `aws deploy stop-deployment --deployment-id <id> --auto-rollback-enabled`.
- **Manual, after completion** — redeploy a previous commit SHA (every image is tagged and kept in ECR), e.g. `git revert` + push, or re-run the older workflow.
- **Local** — `./deploy/local-deploy.sh rollback` (previous color is kept running).

## Security notes

- CI authenticates via **GitHub OIDC federation** — no long-lived AWS keys stored as secrets.
- The deploy role trust policy is scoped to this specific repository.
- App tasks accept traffic **only from the ALB security group**; the ALB exposes only `:80` (prod) and `:9001` (test).
- Images are tagged with immutable commit SHAs — what ran is always traceable to a commit.

## Costs

Demo runs on public subnets without a NAT gateway to stay cheap; still creates an ALB and Fargate tasks (not free tier — roughly the ALB hourly rate plus two 0.25 vCPU tasks). Destroy when done:

```bash
terraform -chdir=terraform destroy
```

## Repository layout

```
app/                      # Spring Boot demo service + Dockerfile
deploy/appspec.yaml       # CodeDeploy ECS appspec
deploy/taskdef.json       # task definition template rendered by CI
deploy/local-deploy.sh    # local blue/green deploy (CodeDeploy simulation)
docker-compose.yml        # local environment: nginx "ALB" + blue/green containers
local/nginx/              # nginx config template rendered per deploy
local/state.env           # local deploy state (active color + tags)
terraform/                # full IaC for the AWS environment
  ├── vpc.tf              # VPC, public subnets, routing
  ├── alb.tf              # ALB, blue/green target groups, prod/test listeners
  ├── ecs.tf              # cluster, bootstrap task definition, service
  ├── codedeploy.tf       # application + blue/green deployment group
  ├── ecr.tf              # image repository
  ├── iam.tf              # task execution, CodeDeploy and GitHub OIDC roles
  └── outputs.tf          # URLs, ARNs, resource names
.github/workflows/        # build/test/push/deploy pipeline
```

## Troubleshooting

- **First ECS task never starts** — the `:bootstrap` image was not pushed to ECR (step 2 of the AWS setup).
- **Workflow fails at "Configure AWS credentials"** — `AWS_DEPLOY_ROLE_ARN` secret missing/wrong, or `github_repository` in Terraform doesn't match the actual repo (OIDC trust policy rejects the token).
- **Deployment stuck then rolled back** — green tasks failed the ALB health check; check the app logs in CloudWatch (`/ecs/ecs-bluegreen-demo`) and confirm `/actuator/health` returns 200 on port 8080.
- **Local deploy: "app did not become healthy"** — check `docker logs ecsdemo-app-blue` (or `-green`); the Spring Boot app needs a few seconds to boot, the script waits up to 60s.

output "alb_dns_name" {
  description = "Public URL of the application"
  value       = "http://${aws_lb.main.dns_name}"
}

output "alb_test_url" {
  description = "Test listener URL (green validation during deploys)"
  value       = "http://${aws_lb.main.dns_name}:9001"
}

output "ecr_repository_url" {
  description = "ECR repository for application images"
  value       = aws_ecr_repository.app.repository_url
}

output "github_deploy_role_arn" {
  description = "Set as AWS_DEPLOY_ROLE_ARN secret in the GitHub repository"
  value       = aws_iam_role.github_deploy.arn
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "codedeploy_application" {
  value = aws_codedeploy_app.app.name
}

output "codedeploy_deployment_group" {
  value = aws_codedeploy_deployment_group.app.deployment_group_name
}

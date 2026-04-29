output "service_name" {
  value = aws_ecs_service.keycloak.name
}

output "service_id" {
  value = aws_ecs_service.keycloak.id
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.keycloak.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.keycloak.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.keycloak.name
}

output "security_group_id" {
  value = aws_security_group.keycloak.id
}

# The relative URL path the ALB routes to Keycloak. Backend uses this
# combined with the ALB DNS to build KEYCLOAK_URL.
output "url_path" {
  value = "/auth"
}

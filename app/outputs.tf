output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

output "application_url" {
  value = "http://${aws_lb.app.dns_name}"
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.app.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}
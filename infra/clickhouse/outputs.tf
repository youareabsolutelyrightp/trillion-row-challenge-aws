output "aws_region" {
  value = var.aws_region
}
output "availability_zone" {
  value = local.selected_az
}
output "run_mode" {
  value = var.run_mode
}
output "instance_type" {
  value = var.instance_type
}
output "instance_count" {
  value = var.instance_count
}
output "market_type" {
  value = var.market_type
}
output "leader_instance_id" {
  value = aws_instance.clickhouse[0].id
}
output "instance_ids" {
  value = aws_instance.clickhouse[*].id
}
output "private_ips" {
  value = aws_instance.clickhouse[*].private_ip
}
output "s3_gateway_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}
output "hard_termination_deadline_minutes" {
  value = var.max_runtime_minutes
}
output "estimated_max_compute_cost_formula" {
  value = "instance_count * max_runtime_minutes / 60 * observed_node_hourly_price"
}

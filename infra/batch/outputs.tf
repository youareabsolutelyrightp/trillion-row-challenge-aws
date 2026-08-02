output "aws_region" {
  value = var.aws_region
}

output "run_mode" {
  value = var.run_mode
}

output "availability_zone" {
  value = local.selected_az
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "output_bucket" {
  value = aws_s3_bucket.output.bucket
}

output "job_queue" {
  value = aws_batch_job_queue.batch.arn
}

output "worker_job_definition" {
  value = aws_batch_job_definition.worker.arn
}

output "reducer_job_definition" {
  value = aws_batch_job_definition.reducer.arn
}

output "compute_environment" {
  value = aws_batch_compute_environment.batch.arn
}

output "s3_gateway_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}

output "array_size" {
  value = var.array_size
}

output "file_count" {
  value = var.file_count
}

output "max_vcpus" {
  value = var.max_vcpus
}

output "worker_vcpus" {
  value = var.worker_vcpus
}

output "worker_memory_mib" {
  value = var.worker_memory_mib
}

output "worker_file_concurrency" {
  value = var.worker_file_concurrency > 0 ? var.worker_file_concurrency : var.worker_vcpus
}

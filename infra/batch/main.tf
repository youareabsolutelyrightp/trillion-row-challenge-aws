data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  selected_az     = coalesce(var.availability_zone, data.aws_availability_zones.available.names[0])
  vpc_cidr        = "10.43.0.0/16"
  subnet_cidr     = "10.43.1.0/24"
  name            = "1trc-batch-rust"
  container_image = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
}

resource "aws_vpc" "batch" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.arn != "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      error_message = "Refusing to provision with the AWS account root user. Use IAM Identity Center or an assumed IAM role."
    }
  }
}

resource "aws_internet_gateway" "batch" {
  vpc_id = aws_vpc.batch.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "batch" {
  vpc_id                  = aws_vpc.batch.id
  availability_zone       = local.selected_az
  cidr_block              = local.subnet_cidr
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name}-public" }
}

resource "aws_route_table" "batch" {
  vpc_id = aws_vpc.batch.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.batch.id
  }
  tags = { Name = local.name }
}

resource "aws_route_table_association" "batch" {
  subnet_id      = aws_subnet.batch.id
  route_table_id = aws_route_table.batch.id
}

data "aws_iam_policy_document" "s3_endpoint" {
  statement {
    sid       = "ReadRequesterPaysDatasetObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::coiled-datasets-rp/1trc/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  statement {
    sid       = "ReadEcrImageLayerObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::prod-${var.aws_region}-starport-layer-bucket/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  statement {
    sid       = "ListRequesterPaysDatasetPrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::coiled-datasets-rp"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  statement {
    sid       = "ReadWriteOutputObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.output.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  statement {
    sid       = "ListOutputBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.output.arn]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.batch.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.batch.id]
  policy            = data.aws_iam_policy_document.s3_endpoint.json
  tags              = { Name = "${local.name}-s3" }
}

resource "aws_security_group" "batch" {
  name        = local.name
  description = "No inbound access; Batch jobs only make outbound requests"
  vpc_id      = aws_vpc.batch.id
  tags        = { Name = local.name }
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.batch.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "ECR, ECS, CloudWatch, STS, and S3 control plane"
}

resource "aws_vpc_security_group_egress_rule" "dns_udp" {
  security_group_id = aws_security_group.batch.id
  cidr_ipv4         = local.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
  description       = "VPC DNS"
}

resource "aws_vpc_security_group_egress_rule" "dns_tcp" {
  security_group_id = aws_security_group.batch.id
  cidr_ipv4         = local.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
  description       = "VPC DNS fallback"
}

resource "aws_s3_bucket" "output" {
  bucket_prefix = "1trc-batch-rust-${data.aws_caller_identity.current.account_id}-"
  force_destroy = true
  tags          = { Name = "${local.name}-output" }
}

resource "aws_s3_bucket_public_access_block" "output" {
  bucket                  = aws_s3_bucket.output.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "output" {
  bucket = aws_s3_bucket.output.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "output" {
  bucket = aws_s3_bucket.output.id
  rule {
    id     = "expire-run-artifacts"
    status = "Enabled"
    filter {
      prefix = ""
    }
    expiration {
      days = var.output_retention_days
    }
  }
}

resource "aws_ecr_repository" "app" {
  name         = local.name
  force_delete = true
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_cloudwatch_log_group" "batch" {
  name              = "/aws/batch/${local.name}"
  retention_in_days = 7
}

data "aws_iam_policy_document" "batch_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["batch.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "batch_service" {
  name_prefix        = "1trc-batch-service-"
  assume_role_policy = data.aws_iam_policy_document.batch_assume_role.json
}

resource "aws_iam_role_policy_attachment" "batch_service" {
  role       = aws_iam_role.batch_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_instance" {
  name_prefix        = "1trc-batch-ecs-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_instance" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name_prefix = "1trc-batch-ecs-"
  role        = aws_iam_role.ecs_instance.name
}

data "aws_iam_policy_document" "spotfleet_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["spotfleet.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "spotfleet" {
  name_prefix        = "1trc-batch-spotfleet-"
  assume_role_policy = data.aws_iam_policy_document.spotfleet_assume_role.json
}

resource "aws_iam_role_policy_attachment" "spotfleet" {
  role       = aws_iam_role.spotfleet.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole"
}

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name_prefix        = "1trc-batch-exec-"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "job" {
  name_prefix        = "1trc-batch-job-"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

data "aws_iam_policy_document" "job" {
  statement {
    sid       = "ReadRequesterPaysDataset"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::coiled-datasets-rp/1trc/*"]
  }
  statement {
    sid       = "ListOutputBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.output.arn]
  }
  statement {
    sid       = "WriteAndReadRunArtifacts"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.output.arn}/*"]
  }
}

resource "aws_iam_role_policy" "job" {
  name   = "1trc-batch-job-s3-access"
  role   = aws_iam_role.job.id
  policy = data.aws_iam_policy_document.job.json
}

resource "aws_batch_compute_environment" "batch" {
  compute_environment_name_prefix = "1trc-batch-rust-"
  service_role                    = aws_iam_role.batch_service.arn
  type                            = "MANAGED"

  compute_resources {
    type                = "SPOT"
    allocation_strategy = var.batch_allocation_strategy
    instance_type       = var.instance_types
    min_vcpus           = 0
    desired_vcpus       = 0
    max_vcpus           = var.max_vcpus
    subnets             = [aws_subnet.batch.id]
    security_group_ids  = [aws_security_group.batch.id]
    instance_role       = aws_iam_instance_profile.ecs_instance.arn
    spot_iam_fleet_role = aws_iam_role.spotfleet.arn
  }

  depends_on = [
    aws_iam_role_policy_attachment.batch_service,
    aws_iam_role_policy_attachment.ecs_instance,
    aws_iam_role_policy_attachment.spotfleet,
  ]
}

resource "aws_batch_job_queue" "batch" {
  name     = local.name
  state    = "ENABLED"
  priority = 1
  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.batch.arn
  }
}

locals {
  worker_container = {
    image            = local.container_image
    command          = ["worker"]
    jobRoleArn       = aws_iam_role.job.arn
    executionRoleArn = aws_iam_role.task_execution.arn
    resourceRequirements = [
      { type = "VCPU", value = tostring(var.worker_vcpus) },
      { type = "MEMORY", value = tostring(var.worker_memory_mib) },
    ]
    environment = concat(
      [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "OUTPUT_BUCKET", value = aws_s3_bucket.output.bucket },
        { name = "FILE_COUNT", value = tostring(var.file_count) },
        { name = "ARRAY_SIZE", value = tostring(var.array_size) },
        { name = "CONTAINER_VCPUS", value = tostring(var.worker_vcpus) },
        { name = "CONTAINER_MEMORY_MIB", value = tostring(var.worker_memory_mib) },
        { name = "RUST_LOG", value = "info" },
      ],
      var.worker_file_concurrency > 0 ? [
        { name = "WORKER_FILE_CONCURRENCY", value = tostring(var.worker_file_concurrency) },
      ] : []
    )
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.batch.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "worker"
      }
    }
  }

  reducer_container = {
    image            = local.container_image
    command          = ["reduce"]
    jobRoleArn       = aws_iam_role.job.arn
    executionRoleArn = aws_iam_role.task_execution.arn
    resourceRequirements = [
      { type = "VCPU", value = tostring(var.reducer_vcpus) },
      { type = "MEMORY", value = tostring(var.reducer_memory_mib) },
    ]
    environment = [
      { name = "AWS_REGION", value = var.aws_region },
      { name = "OUTPUT_BUCKET", value = aws_s3_bucket.output.bucket },
      { name = "ARRAY_SIZE", value = tostring(var.array_size) },
      { name = "MODE", value = var.run_mode },
      { name = "CONTAINER_VCPUS", value = tostring(var.reducer_vcpus) },
      { name = "CONTAINER_MEMORY_MIB", value = tostring(var.reducer_memory_mib) },
      { name = "RUST_LOG", value = "info" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.batch.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "reducer"
      }
    }
  }
}

resource "aws_batch_job_definition" "worker" {
  name                  = "${local.name}-worker"
  type                  = "container"
  platform_capabilities = ["EC2"]
  container_properties  = jsonencode(local.worker_container)
  retry_strategy {
    attempts = 3
  }
  timeout {
    attempt_duration_seconds = var.worker_timeout_seconds
  }
}

resource "aws_batch_job_definition" "reducer" {
  name                  = "${local.name}-reducer"
  type                  = "container"
  platform_capabilities = ["EC2"]
  container_properties  = jsonencode(local.reducer_container)
  retry_strategy {
    attempts = 2
  }
  timeout {
    attempt_duration_seconds = var.reducer_timeout_seconds
  }
}

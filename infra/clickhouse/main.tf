data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  selected_az         = coalesce(var.availability_zone, data.aws_availability_zones.available.names[0])
  vpc_cidr            = "10.42.0.0/16"
  subnet_cidr         = "10.42.1.0/24"
  cluster_private_ips = [for index in range(var.instance_count) : cidrhost(local.subnet_cidr, index + 10)]
}

resource "aws_vpc" "clickhouse" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "1trc-clickhouse" }

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.arn != "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      error_message = "Refusing to provision with the AWS account root user. Use IAM Identity Center or an assumed IAM role."
    }
  }
}

resource "aws_internet_gateway" "clickhouse" {
  vpc_id = aws_vpc.clickhouse.id
  tags   = { Name = "1trc-clickhouse" }
}

resource "aws_subnet" "clickhouse" {
  vpc_id                  = aws_vpc.clickhouse.id
  availability_zone       = local.selected_az
  cidr_block              = local.subnet_cidr
  map_public_ip_on_launch = true
  tags                    = { Name = "1trc-clickhouse-public" }
}

resource "aws_route_table" "clickhouse" {
  vpc_id = aws_vpc.clickhouse.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.clickhouse.id
  }
  tags = { Name = "1trc-clickhouse" }
}

resource "aws_route_table_association" "clickhouse" {
  subnet_id      = aws_subnet.clickhouse.id
  route_table_id = aws_route_table.clickhouse.id
}

data "aws_iam_policy_document" "s3_endpoint" {
  statement {
    sid       = "ReadOnlyRequesterPaysDataset"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::coiled-datasets-rp", "arn:aws:s3:::coiled-datasets-rp/1trc/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.clickhouse.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.clickhouse.id]
  policy            = data.aws_iam_policy_document.s3_endpoint.json
  tags              = { Name = "1trc-clickhouse-s3" }
}

resource "aws_security_group" "clickhouse" {
  name        = "1trc-clickhouse"
  description = "No public ingress; nodes communicate only within this group"
  vpc_id      = aws_vpc.clickhouse.id
  tags        = { Name = "1trc-clickhouse" }
}

resource "aws_vpc_security_group_ingress_rule" "cluster" {
  security_group_id            = aws_security_group.clickhouse.id
  referenced_security_group_id = aws_security_group.clickhouse.id
  ip_protocol                  = "-1"
  description                  = "Intra-cluster traffic"
}

resource "aws_vpc_security_group_egress_rule" "cluster" {
  security_group_id            = aws_security_group.clickhouse.id
  referenced_security_group_id = aws_security_group.clickhouse.id
  ip_protocol                  = "-1"
  description                  = "Intra-cluster traffic"
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.clickhouse.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "S3, SSM, Ubuntu, and ClickHouse repositories"
}

resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.clickhouse.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Package repository bootstrap"
}

resource "aws_vpc_security_group_egress_rule" "dns_udp" {
  security_group_id = aws_security_group.clickhouse.id
  cidr_ipv4         = local.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
  description       = "VPC DNS"
}

resource "aws_vpc_security_group_egress_rule" "dns_tcp" {
  security_group_id = aws_security_group.clickhouse.id
  cidr_ipv4         = local.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
  description       = "VPC DNS fallback"
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

data "aws_iam_policy_document" "scheduler_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "clickhouse" {
  name_prefix        = "1trc-clickhouse-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.clickhouse.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "dataset" {
  statement {
    sid       = "ListOnlyDatasetPrefix"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::coiled-datasets-rp"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["1trc/*"]
    }
  }
  statement {
    sid       = "ReadOnlyDatasetObjects"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::coiled-datasets-rp/1trc/*"]
  }
}

resource "aws_iam_role_policy" "dataset" {
  name   = "requester-pays-dataset-read-only"
  role   = aws_iam_role.clickhouse.id
  policy = data.aws_iam_policy_document.dataset.json
}

resource "aws_iam_instance_profile" "clickhouse" {
  name_prefix = "1trc-clickhouse-"
  role        = aws_iam_role.clickhouse.name
}

resource "aws_iam_role" "scheduler" {
  name_prefix        = "1trc-clickhouse-scheduler-"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume_role.json
}

resource "aws_instance" "clickhouse" {
  count = var.instance_count

  ami                         = data.aws_ami.ubuntu_arm64.id
  instance_type               = var.instance_type
  availability_zone           = local.selected_az
  subnet_id                   = aws_subnet.clickhouse.id
  private_ip                  = local.cluster_private_ips[count.index]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.clickhouse.id]
  iam_instance_profile        = aws_iam_instance_profile.clickhouse.name
  dynamic "instance_market_options" {
    for_each = var.market_type == "spot" ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        instance_interruption_behavior = "terminate"
        max_price                      = var.spot_max_price
        spot_instance_type             = "one-time"
      }
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gib
    encrypted             = true
    delete_on_termination = true
  }

  volume_tags = {
    Name    = format("1trc-clickhouse-%02d-root", count.index)
    Project = "1trc-clickhouse"
  }

  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    cluster_private_ips = local.cluster_private_ips
    vpc_cidr            = local.vpc_cidr
    max_runtime_minutes = var.max_runtime_minutes
    clickhouse_version  = var.clickhouse_version
  })
  user_data_replace_on_change = true

  tags = {
    Name            = format("1trc-clickhouse-%02d", count.index)
    NodeIndex       = tostring(count.index)
    AutoTerminateIn = "${var.max_runtime_minutes} minutes"
    MarketType      = var.market_type
  }

  depends_on = [aws_vpc_endpoint.s3, aws_route_table_association.clickhouse]

  lifecycle {
    precondition {
      condition     = var.clickhouse_version != ""
      error_message = "Pin an exact clickhouse_version before a benchmark."
    }
  }

  timeouts {
    create = "15m"
  }
}

data "aws_iam_policy_document" "scheduled_termination" {
  statement {
    sid       = "TerminateOnlyBenchmarkInstances"
    actions   = ["ec2:TerminateInstances"]
    resources = [for instance in aws_instance.clickhouse : instance.arn]
  }
}

resource "aws_iam_role_policy" "scheduled_termination" {
  name   = "terminate-benchmark-instances"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduled_termination.json
}

resource "aws_scheduler_schedule" "terminate_instance" {
  count = var.instance_count

  name                         = format("1trc-clickhouse-terminate-%02d", count.index)
  description                  = "Cost fuse: terminate 1TRC benchmark node at its TTL"
  schedule_expression          = "at(${formatdate("YYYY-MM-DD'T'hh:mm:ss", timeadd(timestamp(), "${var.max_runtime_minutes}m"))})"
  schedule_expression_timezone = "UTC"
  state                        = "ENABLED"
  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:terminateInstances"
    role_arn = aws_iam_role.scheduler.arn
    input = jsonencode({
      InstanceIds = [aws_instance.clickhouse[count.index].id]
    })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 3
    }
  }

  depends_on = [aws_iam_role_policy.scheduled_termination]
}

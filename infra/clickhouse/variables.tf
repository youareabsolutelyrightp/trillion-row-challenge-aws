variable "aws_region" {
  description = "Must match the dataset region to avoid data-transfer charges."
  type        = string
  default     = "us-east-1"
  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "The dataset is in us-east-1; other regions are intentionally refused."
  }
}

variable "aws_profile" {
  description = "Optional local AWS shared-config profile used by OpenTofu."
  type        = string
  default     = null
  nullable    = true
}

variable "availability_zone" {
  description = "Optional single AZ. One AZ avoids cross-AZ charges."
  type        = string
  default     = null
}

variable "run_mode" {
  description = "Benchmark run label used for tags and output filenames."
  type        = string
  default     = "full"
  validation {
    condition     = var.run_mode == "full"
    error_message = "run_mode must be full."
  }
}

variable "instance_type" {
  description = "ARM64 EC2 instance type."
  type        = string
  default     = "c7g.2xlarge"
}

variable "instance_count" {
  description = "Number of ClickHouse nodes."
  type        = number
  default     = 12
  validation {
    condition     = var.instance_count >= 1 && var.instance_count <= 16 && floor(var.instance_count) == var.instance_count
    error_message = "instance_count must be an integer from 1 through 16."
  }
}

variable "max_runtime_minutes" {
  description = "Hard TTL after which instances terminate themselves."
  type        = number
  default     = 90
  validation {
    condition     = var.max_runtime_minutes >= 20 && var.max_runtime_minutes <= 720
    error_message = "max_runtime_minutes must be between 20 and 720."
  }
}

variable "root_volume_gib" {
  description = "Encrypted gp3 root disk size."
  type        = number
  default     = 30
  validation {
    condition     = var.root_volume_gib >= 12 && var.root_volume_gib <= 100
    error_message = "root_volume_gib must be between 12 and 100 GiB."
  }
}

variable "market_type" {
  description = "EC2 purchase option. Use spot for low cost or on-demand for repeatability."
  type        = string
  default     = "spot"
  validation {
    condition     = contains(["spot", "on-demand"], var.market_type)
    error_message = "market_type must be spot or on-demand."
  }
}

variable "spot_max_price" {
  description = "Optional hourly Spot ceiling; null uses EC2's On-Demand ceiling. Ignored for on-demand."
  type        = string
  default     = null
}

variable "clickhouse_version" {
  description = "Exact ClickHouse package version for reproducible benchmark runs."
  type        = string
  default     = "26.5.2.39"
}

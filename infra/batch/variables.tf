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

variable "run_mode" {
  description = "Benchmark run label used for tags and output filenames."
  type        = string
  default     = "full"
  validation {
    condition     = var.run_mode == "full"
    error_message = "run_mode must be full."
  }
}

variable "availability_zone" {
  description = "Optional single AZ. One AZ avoids cross-AZ charges."
  type        = string
  default     = null
}

variable "instance_types" {
  description = "AWS Batch EC2 instance types for the managed compute environment."
  type        = list(string)
  default     = ["c7g.4xlarge"]
  validation {
    condition     = length(var.instance_types) >= 1
    error_message = "instance_types must contain at least one EC2 instance type."
  }
}

variable "max_vcpus" {
  description = "Maximum vCPUs AWS Batch may provision."
  type        = number
  default     = 96
  validation {
    condition     = var.max_vcpus >= 1 && var.max_vcpus <= 512 && floor(var.max_vcpus) == var.max_vcpus
    error_message = "max_vcpus must be an integer from 1 through 512."
  }
}

variable "worker_vcpus" {
  description = "vCPUs requested by each worker child job."
  type        = number
  default     = 4
  validation {
    condition     = contains([1, 2, 4, 8, 16], var.worker_vcpus)
    error_message = "worker_vcpus must be one of 1, 2, 4, 8, 16."
  }
}

variable "worker_memory_mib" {
  description = "Memory requested by each worker child job."
  type        = number
  default     = 4096
}

variable "worker_file_concurrency" {
  description = "Number of Parquet files each worker reads concurrently."
  type        = number
  default     = 12
  validation {
    condition     = var.worker_file_concurrency >= 0 && var.worker_file_concurrency <= 16 && floor(var.worker_file_concurrency) == var.worker_file_concurrency
    error_message = "worker_file_concurrency must be an integer from 0 through 16."
  }
}

variable "reducer_vcpus" {
  description = "vCPUs requested by the reducer job."
  type        = number
  default     = 2
}

variable "reducer_memory_mib" {
  description = "Memory requested by the reducer job."
  type        = number
  default     = 4096
}

variable "worker_timeout_seconds" {
  description = "Per-worker Batch timeout; cost fuse for stuck shards."
  type        = number
  default     = 3600
}

variable "reducer_timeout_seconds" {
  description = "Reducer Batch timeout; cost fuse for stuck reduction."
  type        = number
  default     = 900
}

variable "array_size" {
  description = "Number of Batch array children for the worker job."
  type        = number
  default     = 120
  validation {
    condition     = var.array_size >= 1 && var.array_size <= 10000 && floor(var.array_size) == var.array_size
    error_message = "array_size must be an integer from 1 through 10000."
  }
}

variable "file_count" {
  description = "Number of dataset Parquet files to process."
  type        = number
  default     = 100000
  validation {
    condition     = var.file_count >= 1 && var.file_count <= 100000 && floor(var.file_count) == var.file_count
    error_message = "file_count must be an integer from 1 through 100000."
  }
}

variable "output_retention_days" {
  description = "S3 lifecycle expiration for temporary run artifacts."
  type        = number
  default     = 7
}

variable "image_tag" {
  description = "Container image tag pushed by the runner."
  type        = string
  default     = "latest"
}

variable "batch_allocation_strategy" {
  description = "Spot allocation strategy. Price-capacity optimized balances interruption and cost."
  type        = string
  default     = "SPOT_PRICE_CAPACITY_OPTIMIZED"
}

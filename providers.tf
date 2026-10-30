provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "terraform"
      Environment = "poc"
    }
  }
}

# AWS Global Accelerator is a global service, but its control-plane API only
# accepts requests in us-west-2 regardless of where its endpoints (e.g. the
# Sydney ALB) actually live. This alias is used solely for the
# aws_globalaccelerator_* resources.
provider "aws" {
  alias  = "global_accelerator"
  region = var.global_accelerator_region

  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "terraform"
      Environment = "poc"
    }
  }
}

# The simulated "near" / client region (Frankfurt by default). The benchmark
# EC2 instance, and the scripts/reports S3 buckets it uses, live here so that
# measurements reflect real client-to-origin network conditions.
provider "aws" {
  alias  = "client"
  region = var.client_region

  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "terraform"
      Environment = "poc"
    }
  }
}

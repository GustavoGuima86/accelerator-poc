variable "project_name" {
  type = string
}

variable "vpc_id" {
  description = "VPC ID for the ALB. If null, the default VPC in the current region is used."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Subnet IDs for the ALB. If null, all subnets in the default VPC are used."
  type        = list(string)
  default     = null
}

variable "allowed_cidr_blocks" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "mock_api_response_body" {
  type = string
}

variable "endpoint_group_region" {
  description = "AWS region where the ALB endpoint actually lives, used by the Global Accelerator endpoint group."
  type        = string
}

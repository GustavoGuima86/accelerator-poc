variable "name" {
  description = "Name tag / prefix for the VPC and its resources."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR. Must not overlap with any VPC it will be peered with."
  type        = string
}

variable "az_count" {
  description = "Number of AZs (one public /24 subnet each). Aurora subnet groups need at least 2."
  type        = number
  default     = 2
}

variable "enable_nat" {
  description = "Create private subnets and a NAT gateway (about $1/day plus data) so functions can reach the internet from one stable Elastic IP."
  type        = bool
  default     = false
}

variable "name" {
  type = string
}

variable "source_dir" {
  description = "Directory containing probe_handler.py and its dependencies (pg8000)."
  type        = string
}

variable "vpc_id" {
  description = "Near-region VPC the function runs in."
  type        = string
}

variable "subnet_ids" {
  description = "PRIVATE subnets with a NAT default route. The NAT's Elastic IP is the stable source address allowed on the public database paths."
  type        = list(string)
}

variable "db_name" {
  type = string
}

variable "db_user" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "primary_endpoint" {
  description = "Aurora writer endpoint (far region)."
  type        = string
}

variable "replica_endpoint" {
  description = "Aurora replica reader endpoint (near region)."
  type        = string
}

variable "batch_api_url" {
  description = "Function URL of the batched-queries API in the far region."
  type        = string
}

variable "batch_api_token" {
  type      = string
  sensitive = true
}

variable "global_accelerator_ip" {
  type = string
}

variable "global_accelerator_port" {
  type    = number
  default = 5432
}

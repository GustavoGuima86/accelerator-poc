variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Public subnet for the TCP forwarder instance."
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "aurora_endpoint" {
  description = "Aurora writer endpoint DNS name. Resolved by the forwarder on every new connection, so it follows failovers."
  type        = string
}

variable "aurora_port" {
  type    = number
  default = 5432
}

variable "aurora_security_group_id" {
  description = "Security group of the Aurora primary; a rule is added allowing the forwarder to reach it."
  type        = string
}

variable "client_cidrs" {
  description = "Client CIDRs allowed to open DB connections to the EC2 endpoint. Global Accelerator preserves the source IP for EC2 endpoints."
  type        = list(string)
}

variable "accelerator_arn" {
  description = "Existing accelerator to add a port-5432 listener to (reuses the API accelerator and its static IPs)."
  type        = string
}

variable "endpoint_group_region" {
  type = string
}

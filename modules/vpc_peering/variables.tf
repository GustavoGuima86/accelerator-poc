variable "name" {
  type = string
}

variable "requester_vpc_id" {
  description = "VPC that initiates the peering (the client/Frankfurt VPC)."
  type        = string
}

variable "requester_dns_resolution_enabled" {
  description = "Allow requester VPC clients to resolve accepter VPC public hostnames to private IPs."
  type        = bool
  default     = false
}

variable "requester_cidr" {
  type = string
}

variable "requester_route_table_ids" {
  description = "Every route table of the requester VPC that needs a route to the accepter (public and, if present, private)."
  type        = list(string)
}

variable "accepter_vpc_id" {
  description = "VPC that accepts the peering (the database/Sydney VPC)."
  type        = string
}

variable "accepter_dns_resolution_enabled" {
  description = "Allow accepter VPC clients to resolve requester VPC public hostnames to private IPs."
  type        = bool
  default     = false
}

variable "accepter_cidr" {
  type = string
}

variable "accepter_route_table_ids" {
  type = list(string)
}

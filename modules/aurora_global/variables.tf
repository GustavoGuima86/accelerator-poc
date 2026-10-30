variable "name" {
  description = "Prefix for cluster identifiers. Aurora cluster names must be unique across all regions of a global database."
  type        = string
}

variable "engine_version" {
  description = "Aurora PostgreSQL version. Must support Global Database, Serverless v2 and global write forwarding in BOTH regions (16.x does)."
  type        = string
  default     = "16.8"
}

variable "min_acu" {
  type    = number
  default = 0.5
}

variable "max_acu" {
  type    = number
  default = 4
}

variable "database_name" {
  type    = string
  default = "benchpoc"
}

variable "master_username" {
  type    = string
  default = "benchadmin"
}

variable "primary_vpc_id" {
  type = string
}

variable "primary_subnet_ids" {
  description = "Public subnets (>= 2 AZs) for the primary cluster, which is deliberately publicly accessible for the direct-access baseline."
  type        = list(string)
}

variable "secondary_vpc_id" {
  type = string
}

variable "secondary_vpc_cidr" {
  description = "CIDR of the secondary (client) VPC. Allowed to reach the secondary cluster and, via VPC peering, the primary cluster."
  type        = string
}

variable "secondary_subnet_ids" {
  description = "Private subnets for the near-region secondary cluster."
  type        = list(string)
}

variable "public_client_cidrs" {
  description = "CIDRs allowed to reach the primary writer over the public internet (the benchmark client's /32 plus anything you add)."
  type        = list(string)
}

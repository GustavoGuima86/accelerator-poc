variable "name" {
  type = string
}

variable "source_dir" {
  description = "Directory containing batch_handler.py and its dependencies (pg8000)."
  type        = string
}

variable "schema_init" {
  description = "Force one initialization invocation after Aurora is created, so the benchmark tables exist before read/write samples."
  type        = bool
  default     = false
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "aurora_security_group_id" {
  description = "Security group of the Aurora primary; a rule is added allowing this Lambda to reach it."
  type        = string
}

variable "db_host" {
  type = string
}

variable "db_port" {
  type    = number
  default = 5432
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

variable "query_count" {
  description = "Default number of sequential queries per invocation (callers can override with ?queries=N)."
  type        = number
  default     = 20
}

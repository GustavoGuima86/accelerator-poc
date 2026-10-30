variable "project_name" {
  type = string
}

variable "instance_type" {
  description = "EC2 instance type for the benchmark client (kept small/cheap; it only runs curl loops)."
  type        = string
  default     = "t3.micro"
}

variable "vpc_id" {
  description = "VPC ID to deploy the benchmark instance into. Leave null to use the default VPC in this provider's region."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Subnet ID to deploy the benchmark instance into. Leave null to use a default subnet in the default VPC."
  type        = string
  default     = null
}

variable "client_public_ip" {
  description = "Stable egress IP when the client is in a private subnet behind NAT. Null for a directly public client in the core-only configuration."
  type        = string
  default     = null
}

variable "benchmark_script_path" {
  description = "Local path to the benchmark.py script that runs the curl loop and writes raw_results.json."
  type        = string
}

variable "report_script_path" {
  description = "Local path to the generate_report.py script that turns raw_results.json into a self-contained HTML report."
  type        = string
}

variable "trigger_script_path" {
  description = "Local path to the trigger_benchmark.sh helper, used both to auto-run the benchmark right after apply and for manual re-runs later."
  type        = string
}

variable "targets" {
  description = "The endpoints to benchmark from this Frankfurt client."
  type = list(object({
    name      = string
    label     = string
    category  = string # "static" or "api"
    optimized = bool
    url       = string
  }))
}

variable "db_benchmark_script_path" {
  description = "Local path to db_benchmark.py (Aurora access-path benchmark)."
  type        = string
}

variable "db_config" {
  description = "Connection details and options for the Aurora benchmark, written into targets.json as its \"db\" section. Null disables the DB benchmark."
  type        = any
  default     = null
  sensitive   = true
}

variable "wait_for" {
  description = "Opaque values (e.g. resource IDs) the first benchmark run must wait on. Passing IDs here, rather than a module-level depends_on, avoids a dependency cycle with resources that need this module's public IP."
  type        = list(string)
  default     = []
}

variable "runs_per_target" {
  description = "Number of sequential requests per target used to compute min/avg/p95."
  type        = number
  default     = 30
}

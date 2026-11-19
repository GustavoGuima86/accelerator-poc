variable "name" {
  type = string
}

variable "source_dir" {
  description = "Directory containing trace_handler.py (no third-party dependencies)."
  type        = string
}

variable "instance_id" {
  description = "Benchmark EC2 instance that actually runs the traceroute."
  type        = string
}

variable "trace_document_name" {
  description = "Name of the SSM command document that runs a traceroute on the instance."
  type        = string
}

variable "targets" {
  description = "Map of target id (static_direct, api_direct, db_direct) to host name to trace to."
  type        = map(string)
}

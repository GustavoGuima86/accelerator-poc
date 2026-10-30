variable "project_name" {
  type = string
}

variable "index_html_path" {
  description = "Local path to the interactive page."
  type        = string
}

variable "config" {
  description = "Object serialised into config.js as window.BENCH_CONFIG (endpoint URLs, payload sizes, optional database probe)."
  type        = any
  sensitive   = true
}

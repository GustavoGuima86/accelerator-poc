variable "project_name" {
  type = string
}

variable "index_html_path" {
  description = "Local path to the sample index.html file to upload."
  type        = string
}

variable "sample_asset_path" {
  description = "Local path to the sample 1MB dummy file to upload."
  type        = string
}

variable "extra_assets" {
  description = "Additional objects to upload, as { object_key = local_file_path }. Mirrors the static_site module so both origins hold identical files."
  type        = map(string)
  default     = {}
}

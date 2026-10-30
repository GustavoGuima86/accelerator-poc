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
  description = "Additional objects to upload, as { object_key = local_file_path }. Used by the interactive page's payload-size selector."
  type        = map(string)
  default     = {}
}

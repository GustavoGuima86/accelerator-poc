output "url" {
  description = "Public URL of the interactive benchmark page."
  value       = "http://${aws_s3_bucket_website_configuration.site.website_endpoint}/"
}

output "bucket" {
  value = aws_s3_bucket.site.id
}

output "bucket_name" {
  value = aws_s3_bucket.direct.id
}

output "website_endpoint" {
  description = "Public S3 static website hosting endpoint (HTTP only, no CDN, no OAC) — the honest 'direct access' baseline for the static asset race."
  value       = aws_s3_bucket_website_configuration.direct.website_endpoint
}

output "index_url" {
  value = "http://${aws_s3_bucket_website_configuration.direct.website_endpoint}/index.html"
}

output "sample_asset_url" {
  value = "http://${aws_s3_bucket_website_configuration.direct.website_endpoint}/${aws_s3_object.sample_asset.key}"
}

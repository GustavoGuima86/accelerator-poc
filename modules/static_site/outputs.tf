output "bucket_name" {
  description = "Name of the private S3 bucket. Direct HTTPS access to this bucket's objects is blocked (public access block + OAC-only bucket policy), demonstrating why the bucket ARN/name is provided for reference instead of a working direct URL."
  value       = aws_s3_bucket.static.id
}

output "bucket_arn" {
  value = aws_s3_bucket.static.arn
}

output "bucket_regional_domain_name" {
  description = "The S3 bucket's regional endpoint. Requesting this directly (e.g. curl) will fail with 403 because the bucket policy only allows reads from the CloudFront distribution via OAC."
  value       = aws_s3_bucket.static.bucket_regional_domain_name
}

output "cloudfront_domain_name" {
  description = "Optimized URL for static assets, served from CloudFront edge locations."
  value       = aws_cloudfront_distribution.static.domain_name
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.static.id
}

output "sample_asset_key" {
  value = aws_s3_object.sample_asset.key
}

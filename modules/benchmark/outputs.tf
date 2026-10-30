output "instance_id" {
  description = "ID of the Frankfurt benchmark EC2 instance, reachable only via SSM Run Command (no SSH, no open inbound ports)."
  value       = aws_instance.benchmark.id
}

output "public_ip" {
  description = "Stable public egress IP of the NAT gateway when the client is in the private Aurora VPC; null for core-only runs."
  value       = var.client_public_ip
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.id
}

output "reports_bucket" {
  value = aws_s3_bucket.reports.id
}

output "reports_website_endpoint" {
  description = "Public S3 static website endpoint serving the generated HTML benchmark report(s)."
  value       = aws_s3_bucket_website_configuration.reports.website_endpoint
}

output "latest_report_url" {
  value = "http://${aws_s3_bucket_website_configuration.reports.website_endpoint}/latest.html"
}

output "ssm_document_name" {
  description = "Name of the SSM document used to (re-)run the benchmark on the instance."
  value       = aws_ssm_document.run_benchmark.name
}

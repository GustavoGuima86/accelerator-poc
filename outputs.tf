# -----------------------------------------------------------------------------
# Static assets: OAC-protected S3 (expected to fail/403) vs CloudFront.
# -----------------------------------------------------------------------------
output "direct_s3_url" {
  description = "OAC-protected S3 bucket reference. This URL is intentionally NOT publicly accessible: the bucket blocks all public access and its policy only allows reads from the CloudFront distribution via Origin Access Control (OAC). Provided for reference (and to prove the 403) rather than as a working baseline URL."
  value       = "https://${module.static_site.bucket_regional_domain_name}/index.html"
}

output "direct_s3_bucket_arn" {
  value = module.static_site.bucket_arn
}

output "cloudfront_domain_name" {
  description = "Optimized URL for static assets (served from CloudFront edge locations)."
  value       = module.static_site.cloudfront_domain_name
}

output "cloudfront_index_url" {
  value = "https://${module.static_site.cloudfront_domain_name}/index.html"
}

output "cloudfront_sample_asset_url" {
  value = "https://${module.static_site.cloudfront_domain_name}/${module.static_site.sample_asset_key}"
}

# -----------------------------------------------------------------------------
# Static assets: HONEST direct-access baseline (separate, insecure bucket
# with the same files) used for the actual speed race, since the
# OAC-protected bucket above is designed to refuse direct requests.
# -----------------------------------------------------------------------------
output "insecure_direct_s3_index_url" {
  description = "Direct S3 website-hosting URL (no CDN, no OAC) — used only as an honest 'direct access' baseline for the latency benchmark. Not a recommended production pattern."
  value       = module.insecure_direct_site.index_url
}

output "insecure_direct_s3_asset_url" {
  value = module.insecure_direct_site.sample_asset_url
}

# -----------------------------------------------------------------------------
# API endpoint: direct ALB vs Global Accelerator.
# -----------------------------------------------------------------------------
output "direct_alb_dns_name" {
  description = "Unoptimized URL for API traffic (direct ALB over the public internet)."
  value       = module.api_endpoint.direct_alb_dns_name
}

output "global_accelerator_ip" {
  description = "Optimized static anycast IP(s) for API traffic (routed over the AWS global network backbone)."
  value       = module.api_endpoint.global_accelerator_ip
}

output "global_accelerator_dns_name" {
  value = module.api_endpoint.global_accelerator_dns_name
}

# -----------------------------------------------------------------------------
# Automated benchmark + report (Frankfurt client).
# -----------------------------------------------------------------------------
output "client_region" {
  value = var.client_region
}

output "benchmark_instance_id" {
  description = "ID of the Frankfurt EC2 instance running the benchmark, reachable only via SSM Run Command (no SSH, no open inbound ports)."
  value       = var.enable_benchmark_client ? module.benchmark[0].instance_id : null
}

output "benchmark_ssm_document_name" {
  description = "SSM document used to (re-)run the benchmark. Re-run any time with: ./scripts/trigger_benchmark.sh"
  value       = var.enable_benchmark_client ? module.benchmark[0].ssm_document_name : null
}

output "benchmark_reports_bucket" {
  value = var.enable_benchmark_client ? module.benchmark[0].reports_bucket : null
}

output "latest_report_url" {
  description = "Shareable URL of the latest generated HTML benchmark report, comparing direct vs. optimized access for both static assets and API traffic."
  value       = var.enable_benchmark_client ? module.benchmark[0].latest_report_url : null
}

# -----------------------------------------------------------------------------
# Interactive page (null when enable_interactive_page = false).
# -----------------------------------------------------------------------------
output "interactive_page_url" {
  description = "Open over HTTP in any browser: static/API tests run from the visitor's own location; the database panel runs from Frankfurt because browsers cannot speak PostgreSQL."
  value       = local.interactive_enabled ? module.interactive_site[0].url : null
}

# -----------------------------------------------------------------------------
# Aurora PostgreSQL global database (null when enable_aurora = false).
# -----------------------------------------------------------------------------
output "aurora_primary_endpoint" {
  description = "Writer endpoint in the far region (public IP from the internet, private IP over VPC peering)."
  value       = local.aurora_enabled ? module.aurora[0].primary_endpoint : null
}

output "aurora_replica_endpoint" {
  description = "Reader endpoint of the near-region replica cluster; also accepts forwarded writes."
  value       = local.aurora_enabled ? module.aurora[0].secondary_reader_endpoint : null
}

output "aurora_global_accelerator_endpoint" {
  description = "host:port for the Global Accelerator path to the database (same static IPs as the API path, port 5432)."
  value       = local.aurora_enabled ? "${module.api_endpoint.global_accelerator_ip[0]}:5432" : null
}

output "aurora_batch_api_url" {
  description = "Function URL of the batched-queries API next to the database. The handler requires the x-bench-token header; the token output is POC-only and the function is public."
  value       = local.aurora_enabled ? module.db_batch_api[0].function_url : null
}

output "aurora_batch_api_token" {
  value     = local.aurora_enabled ? module.db_batch_api[0].token : null
  sensitive = true
}

output "aurora_master_username" {
  value = local.aurora_enabled ? module.aurora[0].master_username : null
}

output "aurora_master_password" {
  description = "Randomly generated POC password. Read with: terraform output -raw aurora_master_password"
  value       = local.aurora_enabled ? module.aurora[0].master_password : null
  sensitive   = true
}

output "benchmark_client_public_ip" {
  description = "Stable NAT egress IP of the Frankfurt benchmark client and DB-probe Lambda; allow-listed on the public DB paths."
  value       = var.enable_benchmark_client ? module.benchmark[0].public_ip : null
}

# -----------------------------------------------------------------------------
# Convenience summary for manual/spot-check curl testing.
# -----------------------------------------------------------------------------
output "latency_test_cheatsheet" {
  description = "Ready-to-run curl commands to compare direct vs. optimized access from your Frankfurt test client."
  value       = <<-EOT
    # Static web page: direct S3 (insecure baseline) vs CloudFront
    curl -w "\nTTFB: %%{time_starttransfer}s  Total: %%{time_total}s  HTTP: %%{http_code}  Cache: %%{header_x-cache}\n" -o /dev/null -s ${module.insecure_direct_site.index_url}
    curl -w "\nTTFB: %%{time_starttransfer}s  Total: %%{time_total}s  HTTP: %%{http_code}  Cache: %%{header_x-cache}\n" -o /dev/null -s https://${module.static_site.cloudfront_domain_name}/index.html

    # Static asset (1MB): direct S3 (insecure baseline) vs CloudFront
    curl -w "\nTTFB: %%{time_starttransfer}s  Total: %%{time_total}s  HTTP: %%{http_code}  Cache: %%{header_x-cache}\n" -o /dev/null -s ${module.insecure_direct_site.sample_asset_url}
    curl -w "\nTTFB: %%{time_starttransfer}s  Total: %%{time_total}s  HTTP: %%{http_code}  Cache: %%{header_x-cache}\n" -o /dev/null -s https://${module.static_site.cloudfront_domain_name}/${module.static_site.sample_asset_key}

    # Security proof: OAC-protected bucket refuses direct access (expect HTTP 403)
    curl -w "\nHTTP: %%{http_code}\n" -o /dev/null -s https://${module.static_site.bucket_regional_domain_name}/index.html

    # API endpoint: direct ALB vs Global Accelerator
    curl -w "\nTTFB: %%{time_starttransfer}s  Total: %%{time_total}s  HTTP: %%{http_code}\n" -o /dev/null -s http://${module.api_endpoint.direct_alb_dns_name}/
    curl -w "\nTTFB: %%{time_starttransfer}s  Total: %%{time_total}s  HTTP: %%{http_code}\n" -o /dev/null -s http://${module.api_endpoint.global_accelerator_ip[0]}/

    # Automated benchmark + HTML report (runs all the above, from Frankfurt, N times each):
    ./scripts/trigger_benchmark.sh
  EOT
}

output "direct_alb_dns_name" {
  description = "Unoptimized URL for API traffic, hitting the ALB directly over the public internet."
  value       = aws_lb.api.dns_name
}

output "alb_arn" {
  value = aws_lb.api.arn
}

output "accelerator_arn" {
  description = "ARN of the accelerator, so other modules (e.g. db_accelerator) can add listeners to the same static IPs."
  value       = aws_globalaccelerator_accelerator.api.id
}

output "global_accelerator_dns_name" {
  description = "Global Accelerator's static DNS name."
  value       = aws_globalaccelerator_accelerator.api.dns_name
}

output "global_accelerator_ip" {
  description = "Optimized static anycast IP(s) for API traffic, routed over the AWS global network backbone."
  value       = [for ip_set in aws_globalaccelerator_accelerator.api.ip_sets : ip_set.ip_addresses][0]
}

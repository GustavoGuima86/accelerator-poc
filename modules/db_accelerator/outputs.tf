output "forwarder_instance_id" {
  value = aws_instance.proxy.id
}

output "endpoint_group_id" {
  value = aws_globalaccelerator_endpoint_group.db.id
}

output "forwarder_public_ip" {
  description = "Public IP of the TCP forwarder; not a stable client endpoint (use the Global Accelerator IPs)."
  value       = aws_instance.proxy.public_ip
}

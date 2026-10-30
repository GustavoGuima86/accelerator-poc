output "vpc_id" {
  value = aws_vpc.this.id
}

output "cidr_block" {
  value = aws_vpc.this.cidr_block
}

output "subnet_ids" {
  description = "Public subnet IDs."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (empty unless enable_nat). Waits for the NAT default route so anything placed here has internet access when it starts."
  value       = aws_subnet.private[*].id

  depends_on = [aws_route.private_nat, aws_route_table_association.private]
}

output "route_table_ids" {
  description = "All route tables (public first, then private when enable_nat). Peering must add its route to every one."
  value       = concat([aws_route_table.public.id], aws_route_table.private[*].id)
}

output "nat_public_ip" {
  description = "Elastic IP all private-subnet internet traffic leaves from (null unless enable_nat)."
  value       = one(aws_eip.nat[*].public_ip)
}

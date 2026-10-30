output "database_name" {
  value = var.database_name
}

output "master_username" {
  value = var.master_username
}

output "master_password" {
  value     = random_password.master.result
  sensitive = true
}

output "port" {
  value = 5432
}

# The depends_on on these two outputs makes anything consuming them wait for
# the DB *instances*, not just the cluster objects (a cluster endpoint exists
# long before it has a writer that can answer queries).
output "primary_endpoint" {
  description = "Writer (cluster) endpoint in the far region. Resolves to a public IP from the internet and to a private IP from inside the VPC / a DNS-enabled peer VPC."
  value       = aws_rds_cluster.primary.endpoint

  depends_on = [aws_rds_cluster_instance.primary_writer, aws_rds_cluster_instance.secondary_reader]
}

output "primary_security_group_id" {
  value = aws_security_group.primary.id
}

output "primary_writer_instance_id" {
  value = aws_rds_cluster_instance.primary_writer.id
}

output "secondary_reader_endpoint" {
  description = "Reader endpoint of the near-region replica cluster (also accepts forwarded writes)."
  value       = aws_rds_cluster.secondary.reader_endpoint

  depends_on = [aws_rds_cluster_instance.primary_writer, aws_rds_cluster_instance.secondary_reader]
}

output "global_cluster_id" {
  value = aws_rds_global_cluster.this.id
}

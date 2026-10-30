resource "random_password" "master" {
  length  = 24
  special = false
}

# -----------------------------------------------------------------------------
# Global cluster container. Storage encryption is required for cross-region
# replicas, and the secondary then needs an explicit KMS key in its region.
# -----------------------------------------------------------------------------
resource "aws_rds_global_cluster" "this" {
  global_cluster_identifier = "${var.name}-global"
  engine                    = "aurora-postgresql"
  engine_version            = var.engine_version
  database_name             = var.database_name
  storage_encrypted         = true
}

# -----------------------------------------------------------------------------
# PRIMARY (far region). One Serverless v2 writer, publicly accessible but
# locked down by security group to the benchmark client and explicit CIDRs.
# -----------------------------------------------------------------------------
resource "aws_security_group" "primary" {
  name        = "${var.name}-aurora-primary"
  description = "Aurora primary (far region)"
  vpc_id      = var.primary_vpc_id
}

# count (not for_each): the benchmark client's /32 is only known after apply.
resource "aws_vpc_security_group_ingress_rule" "primary_public_client" {
  count = length(var.public_client_cidrs)

  security_group_id = aws_security_group.primary.id
  description       = "Public-internet baseline access"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = var.public_client_cidrs[count.index]
}

resource "aws_vpc_security_group_ingress_rule" "primary_peered_client" {
  security_group_id = aws_security_group.primary.id
  description       = "Client VPC via inter-region VPC peering"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = var.secondary_vpc_cidr
}

resource "aws_db_subnet_group" "primary" {
  name       = "${var.name}-aurora-primary"
  subnet_ids = var.primary_subnet_ids
}

resource "aws_rds_cluster" "primary" {
  cluster_identifier        = "${var.name}-primary"
  engine                    = aws_rds_global_cluster.this.engine
  engine_version            = aws_rds_global_cluster.this.engine_version
  global_cluster_identifier = aws_rds_global_cluster.this.id
  database_name             = var.database_name
  master_username           = var.master_username
  master_password           = random_password.master.result
  storage_encrypted         = true

  db_subnet_group_name   = aws_db_subnet_group.primary.name
  vpc_security_group_ids = [aws_security_group.primary.id]

  serverlessv2_scaling_configuration {
    min_capacity = var.min_acu
    max_capacity = var.max_acu
  }

  # Required for synchronous HTTPS database initialization from the probe
  # service and the in-region batching Lambda. Restrict ingress to those roles.
  enable_http_endpoint = true

  backup_retention_period = 1
  skip_final_snapshot     = true
  apply_immediately       = true
}

resource "aws_rds_cluster_instance" "primary_writer" {
  identifier           = "${var.name}-primary-writer"
  cluster_identifier   = aws_rds_cluster.primary.id
  engine               = aws_rds_cluster.primary.engine
  engine_version       = aws_rds_cluster.primary.engine_version
  instance_class       = "db.serverless"
  db_subnet_group_name = aws_db_subnet_group.primary.name
  publicly_accessible  = true
}

# -----------------------------------------------------------------------------
# SECONDARY (near region): read-only replica cluster with global write
# forwarding, so writes sent to it are forwarded to the far-region writer.
# -----------------------------------------------------------------------------
# A dedicated key: the AWS-managed alias/aws/rds key only exists in a region
# after RDS first uses it there, so looking it up can fail on a fresh region.
resource "aws_kms_key" "secondary" {
  provider = aws.secondary

  description             = "${var.name} Aurora secondary cluster"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_security_group" "secondary" {
  provider = aws.secondary

  name        = "${var.name}-aurora-secondary"
  description = "Aurora secondary (near region)"
  vpc_id      = var.secondary_vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "secondary_client_vpc" {
  provider = aws.secondary

  security_group_id = aws_security_group.secondary.id
  description       = "Client VPC"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = var.secondary_vpc_cidr
}

resource "aws_db_subnet_group" "secondary" {
  provider = aws.secondary

  name       = "${var.name}-aurora-secondary"
  subnet_ids = var.secondary_subnet_ids
}

resource "aws_rds_cluster" "secondary" {
  provider = aws.secondary

  cluster_identifier        = "${var.name}-secondary"
  engine                    = aws_rds_global_cluster.this.engine
  engine_version            = aws_rds_global_cluster.this.engine_version
  global_cluster_identifier = aws_rds_global_cluster.this.id
  source_region             = data.aws_region.primary.name
  storage_encrypted         = true
  kms_key_id                = aws_kms_key.secondary.arn

  enable_global_write_forwarding = true

  db_subnet_group_name   = aws_db_subnet_group.secondary.name
  vpc_security_group_ids = [aws_security_group.secondary.id]

  serverlessv2_scaling_configuration {
    min_capacity = var.min_acu
    max_capacity = var.max_acu
  }

  skip_final_snapshot = true
  apply_immediately   = true

  lifecycle {
    ignore_changes = [replication_source_identifier]
  }

  # The secondary can only be created once the primary has a writer.
  depends_on = [aws_rds_cluster_instance.primary_writer]
}

data "aws_region" "primary" {}

resource "aws_rds_cluster_instance" "secondary_reader" {
  provider = aws.secondary

  identifier           = "${var.name}-secondary-reader"
  cluster_identifier   = aws_rds_cluster.secondary.id
  engine               = aws_rds_cluster.secondary.engine
  engine_version       = aws_rds_cluster.secondary.engine_version
  instance_class       = "db.serverless"
  db_subnet_group_name = aws_db_subnet_group.secondary.name
  publicly_accessible  = false
}

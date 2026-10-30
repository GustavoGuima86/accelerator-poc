locals {
  health_check_port = 8080
}

# Global Accelerator checks EC2 endpoints from Route 53 health-checker ranges;
# keep this ingress rule on a dedicated port, separate from the DB listener.
data "aws_ip_ranges" "route53_healthchecks" {
  services = ["route53_healthchecks"]
}

resource "aws_security_group" "proxy" {
  name        = "${var.name}-db-forwarder"
  description = "TCP forwarder in front of Aurora, reached via Global Accelerator"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "clients" {
  count = length(var.client_cidrs)

  security_group_id = aws_security_group.proxy.id
  description       = "DB clients via Global Accelerator (client IP preserved)"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = var.client_cidrs[count.index]
}

# Health checks use a separate port so the DB port is never opened to the
# Route 53 checker ranges.
resource "aws_vpc_security_group_ingress_rule" "health_checks" {
  for_each = toset(data.aws_ip_ranges.route53_healthchecks.cidr_blocks)

  security_group_id = aws_security_group.proxy.id
  description       = "Global Accelerator health check"
  ip_protocol       = "tcp"
  from_port         = local.health_check_port
  to_port           = local.health_check_port
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.proxy.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "aurora_from_proxy" {
  security_group_id            = var.aurora_security_group_id
  description                  = "TCP forwarder"
  ip_protocol                  = "tcp"
  from_port                    = var.aurora_port
  to_port                      = var.aurora_port
  referenced_security_group_id = aws_security_group.proxy.id
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "proxy" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.proxy.id]
  associate_public_ip_address = true

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/user_data.sh.tpl", {
    aurora_endpoint   = var.aurora_endpoint
    aurora_port       = var.aurora_port
    health_check_port = local.health_check_port
  })

  tags = {
    Name = "${var.name}-db-forwarder"
  }
}

# -----------------------------------------------------------------------------
# Port-5432 listener on the existing accelerator, pointing at the forwarder.
# -----------------------------------------------------------------------------
resource "aws_globalaccelerator_listener" "db" {
  provider = aws.global_accelerator

  accelerator_arn = var.accelerator_arn
  client_affinity = "SOURCE_IP"
  protocol        = "TCP"

  port_range {
    from_port = 5432
    to_port   = 5432
  }
}

resource "aws_globalaccelerator_endpoint_group" "db" {
  provider = aws.global_accelerator

  listener_arn          = aws_globalaccelerator_listener.db.id
  endpoint_group_region = var.endpoint_group_region

  health_check_protocol = "TCP"
  health_check_port     = local.health_check_port

  endpoint_configuration {
    endpoint_id                    = aws_instance.proxy.id
    weight                         = 100
    client_ip_preservation_enabled = true
  }
}

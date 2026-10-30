data "aws_vpc" "selected" {
  id      = var.vpc_id
  default = var.vpc_id == null ? true : null
}

data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }

  dynamic "filter" {
    for_each = var.subnet_ids == null ? [1] : []
    content {
      name   = "default-for-az"
      values = ["true"]
    }
  }
}

locals {
  subnet_ids = var.subnet_ids != null ? var.subnet_ids : data.aws_subnets.selected.ids
}

# -----------------------------------------------------------------------------
# Security group allowing HTTP to the ALB (direct-access baseline path).
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow inbound HTTP to the mock API ALB"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------------------------------------------------------
# Application Load Balancer mocking an EKS API endpoint.
# -----------------------------------------------------------------------------
resource "aws_lb" "api" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.subnet_ids
}

# Dummy target group representing the (unused) EKS backend. No targets are
# registered since the listener responds directly with a fixed response.
resource "aws_lb_target_group" "api" {
  name        = "${var.project_name}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.selected.id
  target_type = "ip"

  health_check {
    path                = "/"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  # Lets the interactive benchmark page time this endpoint from a browser
  # (simple GET requests only need this one header).
  routing_http_response_access_control_allow_origin_header_value = "*"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = var.mock_api_response_body
      status_code  = "200"
    }
  }
}

# -----------------------------------------------------------------------------
# AWS Global Accelerator in front of the ALB.
# Note: the control-plane API for Global Accelerator must be called in
# us-west-2 regardless of where the accelerator's endpoints are located,
# hence the aws.global_accelerator provider alias.
# -----------------------------------------------------------------------------
resource "aws_globalaccelerator_accelerator" "api" {
  provider = aws.global_accelerator

  name            = "${var.project_name}-ga"
  ip_address_type = "IPV4"
  enabled         = true
}

resource "aws_globalaccelerator_listener" "api" {
  provider = aws.global_accelerator

  accelerator_arn = aws_globalaccelerator_accelerator.api.id
  client_affinity = "NONE"
  protocol        = "TCP"

  port_range {
    from_port = 80
    to_port   = 80
  }
}

resource "aws_globalaccelerator_endpoint_group" "api" {
  provider = aws.global_accelerator

  listener_arn          = aws_globalaccelerator_listener.api.id
  endpoint_group_region = var.endpoint_group_region

  endpoint_configuration {
    endpoint_id = aws_lb.api.arn
    weight      = 100
  }

  health_check_path     = "/"
  health_check_protocol = "HTTP"
  health_check_port     = 80
}

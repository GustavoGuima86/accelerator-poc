resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  artifacts_bucket_name = "${var.project_name}-bench-artifacts-${random_id.suffix.hex}"
  reports_bucket_name   = "${var.project_name}-bench-reports-${random_id.suffix.hex}"
}

data "aws_region" "current" {}

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
    for_each = var.subnet_id == null ? [1] : []
    content {
      name   = "default-for-az"
      values = ["true"]
    }
  }
}

locals {
  subnet_id = var.subnet_id != null ? var.subnet_id : data.aws_subnets.selected.ids[0]
}

# -----------------------------------------------------------------------------
# Artifacts bucket: holds the benchmark/report scripts and raw JSON results.
# Private; the EC2 instance reads/writes via its instance role.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket        = local.artifacts_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The DB config object contains a randomly generated database password and
# function tokens. The EC2 benchmark client fetches it at run time; both bucket
# and object use SSE-S3. Raw results explicitly strip secrets before upload.
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "benchmark_script" {
  bucket       = aws_s3_bucket.artifacts.id
  key          = "scripts/benchmark.py"
  source       = var.benchmark_script_path
  etag         = filemd5(var.benchmark_script_path)
  content_type = "text/x-python"
}

resource "aws_s3_object" "db_benchmark_script" {
  bucket       = aws_s3_bucket.artifacts.id
  key          = "scripts/db_benchmark.py"
  source       = var.db_benchmark_script_path
  etag         = filemd5(var.db_benchmark_script_path)
  content_type = "text/x-python"
}

resource "aws_s3_object" "report_script" {
  bucket       = aws_s3_bucket.artifacts.id
  key          = "scripts/generate_report.py"
  source       = var.report_script_path
  etag         = filemd5(var.report_script_path)
  content_type = "text/x-python"
}

# Resolved target list, rendered to JSON by Terraform (all URLs are already
# known after apply), so the EC2 instance just downloads and runs it — no
# need to re-derive URLs on the client side.
resource "aws_s3_object" "targets" {
  bucket                 = aws_s3_bucket.artifacts.id
  key                    = "targets/targets.json"
  content_type           = "application/json"
  server_side_encryption = "AES256"
  # Contains the (POC-only, randomly generated) DB password, hence the private
  # bucket + encryption. Terraform state holds it as well; see the README.
  content = jsonencode({
    runs_per_target = var.runs_per_target
    targets         = var.targets
    db              = var.db_config
  })
}

# -----------------------------------------------------------------------------
# Reports bucket: PUBLIC read, static website hosting, so the generated HTML
# report can be shared with stakeholders via a plain URL. Contains only
# synthetic benchmark numbers (no sensitive data) — same "demo-only, do not
# replicate in production" caveat as the insecure_direct_site module.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "reports" {
  bucket        = local.reports_bucket_name
  force_destroy = true

  tags = {
    Purpose = "public-benchmark-report-demo-only"
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_ownership_controls" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_website_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  index_document {
    suffix = "latest.html"
  }
}

data "aws_iam_policy_document" "reports_public_read" {
  statement {
    sid    = "PublicReadGetObject"
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.reports.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "reports" {
  bucket = aws_s3_bucket.reports.id
  policy = data.aws_iam_policy_document.reports_public_read.json

  depends_on = [aws_s3_bucket_public_access_block.reports]
}

# -----------------------------------------------------------------------------
# IAM role for the benchmark EC2 instance: SSM Run Command (no SSH/open
# ports needed) + scoped S3 read/write on the two buckets above.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "benchmark" {
  name               = "${var.project_name}-benchmark-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.benchmark.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "benchmark_s3" {
  statement {
    sid       = "ReadArtifacts"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "ReadArtifactsBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = [aws_s3_bucket.artifacts.arn]
  }

  statement {
    sid       = "WriteArtifacts"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/results/*"]
  }

  statement {
    sid       = "WriteReports"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.reports.arn}/*"]
  }

  statement {
    sid       = "ReadReportsBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = [aws_s3_bucket.reports.arn]
  }

  statement {
    sid       = "ReadReportsBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = [aws_s3_bucket.reports.arn]
  }
}

resource "aws_iam_role_policy" "benchmark_s3" {
  name   = "${var.project_name}-benchmark-s3"
  role   = aws_iam_role.benchmark.id
  policy = data.aws_iam_policy_document.benchmark_s3.json
}

resource "aws_iam_instance_profile" "benchmark" {
  name = "${var.project_name}-benchmark-profile"
  role = aws_iam_role.benchmark.name
}

# -----------------------------------------------------------------------------
# Benchmark EC2 instance: no inbound access at all. It is driven entirely via
# SSM Run Command, so there is nothing to SSH into and no open ports.
# -----------------------------------------------------------------------------
resource "aws_security_group" "benchmark" {
  name        = "${var.project_name}-benchmark-sg"
  description = "No inbound access; outbound only, for SSM + S3 + curl to target endpoints"
  vpc_id      = data.aws_vpc.selected.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Amazon Linux 2023 ships with Python 3, curl and the SSM Agent preinstalled,
# so no custom AMI or bootstrap script is required.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "benchmark" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.benchmark.id]
  iam_instance_profile        = aws_iam_instance_profile.benchmark.name
  associate_public_ip_address = var.subnet_id == null

  tags = {
    Name = "${var.project_name}-benchmark-client"
  }
}

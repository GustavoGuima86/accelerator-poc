# -----------------------------------------------------------------------------
# DELIBERATELY INSECURE bucket, used only to produce an honest "direct S3"
# baseline for the latency race. It is NOT the OAC-protected bucket used
# elsewhere in this POC — it exists solely to answer "how fast/slow is S3
# website hosting without a CDN in front of it, for the exact same files?".
#
# Do not reuse this pattern outside of this benchmark: public, unauthenticated
# S3 website hosting is almost never appropriate for production static sites;
# see the static_site module (CloudFront + OAC) for the recommended pattern.
# -----------------------------------------------------------------------------
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  bucket_name = "${var.project_name}-insecure-direct-${random_id.suffix.hex}"
}

resource "aws_s3_bucket" "direct" {
  bucket        = local.bucket_name
  force_destroy = true

  tags = {
    Purpose = "insecure-direct-access-benchmark-only"
    Warning = "public-website-hosting-do-not-replicate-in-production"
  }
}

resource "aws_s3_bucket_public_access_block" "direct" {
  bucket = aws_s3_bucket.direct.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_ownership_controls" "direct" {
  bucket = aws_s3_bucket.direct.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_website_configuration" "direct" {
  bucket = aws_s3_bucket.direct.id

  index_document {
    suffix = "index.html"
  }
}

# CORS so the interactive benchmark page can time this origin from a browser.
resource "aws_s3_bucket_cors_configuration" "direct" {
  bucket = aws_s3_bucket.direct.id

  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
    allowed_headers = ["*"]
    expose_headers  = ["Content-Length", "ETag"]
    max_age_seconds = 600
  }
}

resource "aws_s3_object" "extra_assets" {
  for_each = var.extra_assets

  bucket       = aws_s3_bucket.direct.id
  key          = each.key
  source       = each.value
  etag         = filemd5(each.value)
  content_type = "application/octet-stream"

  depends_on = [aws_s3_bucket_policy.direct]
}

data "aws_iam_policy_document" "public_read" {
  statement {
    sid    = "PublicReadGetObject"
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.direct.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "direct" {
  bucket = aws_s3_bucket.direct.id
  policy = data.aws_iam_policy_document.public_read.json

  depends_on = [aws_s3_bucket_public_access_block.direct]
}

# Same sample files as the CloudFront-protected bucket, so the benchmark
# compares identical payloads.
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.direct.id
  key          = "index.html"
  source       = var.index_html_path
  etag         = filemd5(var.index_html_path)
  content_type = "text/html"

  depends_on = [aws_s3_bucket_policy.direct]
}

resource "aws_s3_object" "sample_asset" {
  bucket       = aws_s3_bucket.direct.id
  key          = "dummy-1mb.bin"
  source       = var.sample_asset_path
  etag         = filemd5(var.sample_asset_path)
  content_type = "application/octet-stream"

  depends_on = [aws_s3_bucket_policy.direct]
}

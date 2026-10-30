resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  bucket_name = "${var.project_name}-static-${random_id.suffix.hex}"
}

# -----------------------------------------------------------------------------
# S3 bucket (private) - the "origin" for both the direct-access baseline test
# and the CloudFront-optimized test.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "static" {
  bucket        = local.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "static" {
  bucket = aws_s3_bucket.static.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "static" {
  bucket = aws_s3_bucket.static.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "static" {
  bucket = aws_s3_bucket.static.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Sample objects used to measure TTFB / download time differences.
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.static.id
  key          = "index.html"
  source       = var.index_html_path
  etag         = filemd5(var.index_html_path)
  content_type = "text/html"
}

resource "aws_s3_object" "sample_asset" {
  bucket       = aws_s3_bucket.static.id
  key          = "dummy-1mb.bin"
  source       = var.sample_asset_path
  etag         = filemd5(var.sample_asset_path)
  content_type = "application/octet-stream"
}

resource "aws_s3_object" "extra_assets" {
  for_each = var.extra_assets

  bucket       = aws_s3_bucket.static.id
  key          = each.key
  source       = each.value
  etag         = filemd5(each.value)
  content_type = "application/octet-stream"
}

# CORS for the interactive benchmark page, which times these URLs from the
# visitor's browser. Also exposes CloudFront's own diagnostic headers so the
# page can show cache Hit/Miss and which edge location answered.
resource "aws_cloudfront_response_headers_policy" "cors" {
  name    = "${var.project_name}-cors-${random_id.suffix.hex}"
  comment = "CORS + exposed diagnostics for the interactive latency page"

  cors_config {
    access_control_allow_credentials = false
    access_control_max_age_sec       = 600
    origin_override                  = true

    access_control_allow_headers {
      items = ["*"]
    }

    access_control_allow_methods {
      items = ["GET", "HEAD"]
    }

    access_control_allow_origins {
      items = ["*"]
    }

    access_control_expose_headers {
      items = ["x-cache", "x-amz-cf-pop", "x-amz-cf-id", "age"]
    }
  }
}

# -----------------------------------------------------------------------------
# CloudFront distribution with Origin Access Control (OAC).
# OAC ensures the S3 bucket can only be read through CloudFront, so direct
# S3 URLs (the baseline/unoptimized path in this POC) return 403.
# -----------------------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "static" {
  name                              = "${var.project_name}-oac"
  description                       = "OAC for ${local.bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "static" {
  enabled             = true
  comment             = "${var.project_name} static asset CDN"
  default_root_object = "index.html"
  price_class         = "PriceClass_All"

  origin {
    domain_name              = aws_s3_bucket.static.bucket_regional_domain_name
    origin_id                = "s3-${local.bucket_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.static.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-${local.bucket_name}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.cors.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# -----------------------------------------------------------------------------
# Bucket policy: allow reads only from this specific CloudFront distribution
# (enforced via the AWS:SourceArn condition on the OAC service principal).
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "cloudfront_oac" {
  statement {
    sid    = "AllowCloudFrontServicePrincipalReadOnly"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.static.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.static.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "static" {
  bucket = aws_s3_bucket.static.id
  policy = data.aws_iam_policy_document.cloudfront_oac.json
}

resource "random_password" "token" {
  length  = 32
  special = false
}

data "archive_file" "function" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/trace_probe.zip"
  excludes    = ["__pycache__", "**/__pycache__/**"]
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-trace-probe"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# The function drives the benchmark EC2 via SSM Run Command and reads the
# result. SendCommand is scoped to this one instance and this one document;
# GetCommandInvocation/DescribeInstanceInformation do NOT support
# resource-level permissions in IAM (AWS requires Resource "*" for them), so
# scoping those to the instance ARN would silently deny every read at
# runtime. Read access stays read-only and this role can target no other
# instance, so "*" here does not widen what the function can actually do.
data "aws_iam_policy_document" "ssm" {
  statement {
    sid     = "RunTraceCommand"
    effect  = "Allow"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${var.instance_id}",
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:document/${var.trace_document_name}",
    ]
  }

  statement {
    sid       = "ReadTraceResult"
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation", "ssm:DescribeInstanceInformation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ssm" {
  name   = "${var.name}-trace-probe-ssm"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.ssm.json
}

resource "aws_lambda_function" "this" {
  function_name    = "${var.name}-trace-probe"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "trace_handler.handler"
  filename         = data.archive_file.function.output_path
  source_code_hash = data.archive_file.function.output_base64sha256
  # A real traceroute across ~30 hops takes ~1-2 min, plus SSM polling and the
  # one-off tool install on the instance. Keep the URL alive for all of it.
  timeout     = 290
  memory_size = 256
  # A traceroute is comparatively expensive to run; two at a time lets the
  # page trace a direct and an optimized target in parallel during one Run,
  # while still bounding what a shared link can trigger.
  reserved_concurrent_executions = 2

  lifecycle {
    ignore_changes = [filename]
  }

  environment {
    variables = {
      TOKEN         = random_password.token.result
      INSTANCE_ID   = var.instance_id
      DOCUMENT_NAME = var.trace_document_name
      TARGETS       = jsonencode(var.targets)
    }
  }

  depends_on = [aws_iam_role_policy_attachment.basic, aws_iam_role_policy.ssm]
}

# Public Function URL called from visitors' browsers. CORS is open; the token is
# a query parameter so the request stays "simple" (no preflight round trip).
resource "aws_lambda_function_url" "this" {
  function_name      = aws_lambda_function.this.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = ["*"]
    allow_methods = ["GET"]
    max_age       = 600
  }
}

resource "aws_lambda_permission" "url_invoke" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.this.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# Needed since late 2025 for NONE-auth function URLs (same caveat as db_probe).
resource "aws_lambda_permission" "url_invoke_function" {
  statement_id  = "AllowPublicFunctionUrlInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "*"
}

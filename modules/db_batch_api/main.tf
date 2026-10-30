resource "random_password" "token" {
  length  = 32
  special = false
}

data "archive_file" "function" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/db_batch_api.zip"
  excludes    = ["__pycache__", "**/__pycache__/**"]
}

resource "aws_security_group" "lambda" {
  name        = "${var.name}-db-batch-lambda"
  description = "Lambda running the batched DB workload next to Aurora"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "aurora_from_lambda" {
  security_group_id            = var.aurora_security_group_id
  description                  = "Batch API Lambda"
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
  referenced_security_group_id = aws_security_group.lambda.id
}

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
  name               = "${var.name}-db-batch-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_lambda_function" "this" {
  function_name    = "${var.name}-db-batch"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "batch_handler.handler"
  filename         = data.archive_file.function.output_path
  source_code_hash = data.archive_file.function.output_base64sha256
  timeout          = 30
  memory_size      = 256
  # This is a public POC function URL. Keep a hard ceiling on concurrent
  # invokes (including unwanted ones) to limit unexpected DB load/cost.
  reserved_concurrent_executions = 2

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_HOST     = var.db_host
      DB_PORT     = tostring(var.db_port)
      DB_NAME     = var.db_name
      DB_USER     = var.db_user
      DB_PASSWORD = var.db_password
      BENCH_TOKEN = random_password.token.result
      QUERY_COUNT = tostring(var.query_count)
    }
  }

  lifecycle {
    # The function source archive is shared with the probe function; each
    # module has its own ZIP output path, and this stable hash tracks the source.
    ignore_changes = [filename]
  }

  depends_on = [aws_iam_role_policy_attachment.vpc_access]
}

# Public Function URL, protected only by the shared-secret header checked in
# the handler. Fine for a short-lived POC; use AWS_IAM auth for anything real.
resource "aws_lambda_function_url" "this" {
  function_name      = aws_lambda_function.this.function_name
  authorization_type = "NONE"

  # So the interactive page can call it from a browser. The token is sent as a
  # query parameter (?t=) there, which keeps the request "simple" and avoids a
  # CORS preflight round trip that would distort the measured latency.
  cors {
    allow_origins = ["*"]
    allow_methods = ["GET"]
    allow_headers = ["x-bench-token"]
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

# Since late 2025 a NONE-auth function URL also needs lambda:InvokeFunction, or
# unsigned calls get 403. AWS recommends scoping it with the
# lambda:InvokedViaFunctionUrl condition, which this provider version cannot
# express, so the statement is unconditioned. The handler's shared-secret
# header check is what actually protects the function; fine for a short-lived
# POC, not for production.
resource "aws_lambda_permission" "url_invoke_function" {
  statement_id  = "AllowPublicFunctionUrlInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "*"
}

# DDL cannot be forwarded from a global secondary cluster. Invoke the Sydney
# function after deployment so it creates/seeds tables through the actual
# primary writer before the interactive Frankfurt probe starts.
resource "terraform_data" "schema_init" {
  count = var.schema_init ? 1 : 0

  input = var.schema_init

  triggers_replace = [
    aws_lambda_function.this.arn,
    var.schema_init,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      for attempt in $(seq 1 60); do
        code=$(curl -sS -o /dev/null -w '%%{http_code}' -H 'x-bench-token: ${random_password.token.result}' '${aws_lambda_function_url.this.function_url}?queries=1')
        if [ "$code" = "200" ]; then exit 0; fi
        sleep 10
      done
      echo "Failed to initialize benchmark schema through the primary DB Lambda (last HTTP $code)" >&2
      exit 1
    EOT
  }

  depends_on = [aws_lambda_permission.url_invoke, aws_lambda_permission.url_invoke_function]
}

resource "random_password" "token" {
  length  = 32
  special = false
}

data "archive_file" "function" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/db_probe.zip"
  excludes    = ["__pycache__", "**/__pycache__/**"]
}

resource "aws_security_group" "lambda" {
  name        = "${var.name}-db-probe"
  description = "Lambda that runs database benchmark sessions from the near region"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
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
  name               = "${var.name}-db-probe"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_lambda_function" "this" {
  function_name    = "${var.name}-db-probe"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "probe_handler.handler"
  filename         = data.archive_file.function.output_path
  source_code_hash = data.archive_file.function.output_base64sha256
  # 50 sequential statements at ~300 ms each is ~15 s, plus connection setup.
  timeout     = 60
  memory_size = 256
  # The URL is public and the demo token is embedded in the public page config.
  # Cap concurrent probes so a shared demo link cannot create unbounded DB load.
  reserved_concurrent_executions = 2

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  lifecycle {
    ignore_changes = [filename]
  }

  environment {
    variables = {
      DB_NAME          = var.db_name
      DB_USER          = var.db_user
      DB_PASSWORD      = var.db_password
      DB_PORT          = tostring(var.db_port)
      PRIMARY_ENDPOINT = var.primary_endpoint
      REPLICA_ENDPOINT = var.replica_endpoint
      GA_IP            = var.global_accelerator_ip
      GA_PORT          = tostring(var.global_accelerator_port)
      BATCH_API_URL    = var.batch_api_url
      BATCH_TOKEN      = var.batch_api_token
      BENCH_TOKEN      = random_password.token.result
    }
  }

  depends_on = [aws_iam_role_policy_attachment.vpc_access]
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

# Needed since late 2025 for NONE-auth function URLs. This provider version
# cannot express lambda:InvokedViaFunctionUrl, so direct InvokeFunction calls
# are technically allowed too; the handler token and concurrency cap are the
# short-lived POC's abuse controls.
resource "aws_lambda_permission" "url_invoke_function" {
  statement_id  = "AllowPublicFunctionUrlInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "*"
}

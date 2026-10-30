output "function_url" {
  value = aws_lambda_function_url.this.function_url
}

output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "token" {
  value     = random_password.token.result
  sensitive = true
}

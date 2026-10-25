variable "device_token_hash" {
  type      = string
  sensitive = true
  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.device_token_hash))
    error_message = "Supply the SHA256 digest of the private device token, never the token itself."
  }
}
resource "aws_dynamodb_table" "uploads" {
  name         = "iseeyou-teacher-uploads"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
  attribute {
    name = "session_id"
    type = "S"
  }
  global_secondary_index {
    name            = "session-index"
    hash_key        = "session_id"
    range_key       = "id"
    projection_type = "ALL"
  }
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
  server_side_encryption { enabled = true }
}
resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/iseeyou-teacher-ingestion"
  retention_in_days = 7
}
resource "aws_iam_role" "api" {
  name               = "iseeyou-teacher-ingestion"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy" "api" {
  role = aws_iam_role.api.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = ["${aws_s3_bucket.data.arn}/raw/*", "${aws_s3_bucket.data.arn}/local/raw/*"] },
    { Effect = "Allow", Action = "s3:GetObject", Resource = ["${aws_s3_bucket.data.arn}/candidates/*", "${aws_s3_bucket.data.arn}/learning/releases/*"] },
    { Effect = "Allow", Action = "s3:ListBucket", Resource = aws_s3_bucket.data.arn },
    { Effect = "Allow", Action = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"], Resource = aws_dynamodb_table.uploads.arn },
    { Effect = "Allow", Action = ["states:StartExecution"], Resource = aws_sfn_state_machine.learning.arn },
    { Effect = "Allow", Action = ["sagemaker:DescribeTrainingJob"], Resource = "*" },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.api.arn}:*" }
  ] })
}
resource "aws_lambda_function" "api" {
  function_name    = "iseeyou-teacher-ingestion"
  role             = aws_iam_role.api.arn
  runtime          = "python3.12"
  handler          = "ingestion.handler"
  filename         = data.archive_file.worker.output_path
  source_code_hash = data.archive_file.worker.output_base64sha256
  timeout          = 20
  memory_size      = 128
  environment { variables = { BUCKET = aws_s3_bucket.data.id, TABLE = aws_dynamodb_table.uploads.id, TOKEN_HASH = var.device_token_hash, WORKFLOW_ARN = aws_sfn_state_machine.learning.arn } }
  depends_on = [aws_iam_role_policy.api]
}
resource "aws_apigatewayv2_api" "uploads" {
  name          = "iseeyou-teacher-ingestion"
  protocol_type = "HTTP"
}
resource "aws_apigatewayv2_integration" "uploads" {
  api_id                 = aws_apigatewayv2_api.uploads.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}
resource "aws_apigatewayv2_route" "uploads" {
  for_each  = toset(["POST /samples", "POST /samples/{sample}/complete", "GET /samples/{sample}", "POST /sessions/{session}/complete", "GET /sessions/{session}", "GET /models/latest", "POST /models/{version}/feedback"])
  api_id    = aws_apigatewayv2_api.uploads.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.uploads.id}"
}
resource "aws_apigatewayv2_stage" "uploads" {
  api_id      = aws_apigatewayv2_api.uploads.id
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    throttling_burst_limit = 2
    throttling_rate_limit  = 2
  }
}
resource "aws_lambda_permission" "api" {
  statement_id   = "AllowUploadGateway"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.api.function_name
  principal      = "apigateway.amazonaws.com"
  source_arn     = "${aws_apigatewayv2_api.uploads.execution_arn}/*/*"
  source_account = local.account
}
output "upload_api_url" { value = aws_apigatewayv2_api.uploads.api_endpoint }

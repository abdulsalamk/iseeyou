terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.7" }
  }
  backend "s3" {}
}
provider "aws" {
  region              = "eu-west-2"
  allowed_account_ids = ["885625664603"]
  default_tags { tags = { Project = "iseeyou", Purpose = "SilentTeacher" } }
}
variable "model_access_ready" {
  type        = bool
  default     = false
  description = "Enable queue consumption only after account-level Bedrock model access is confirmed."
}
variable "teacher_model_id" {
  type    = string
  default = "amazon.nova-lite-v1:0"
  validation {
    condition     = can(regex("^[a-z0-9.-]+:[a-z0-9]+$", var.teacher_model_id))
    error_message = "Use a regional foundation model ID supporting on-demand Converse images."
  }
}
locals {
  name    = "iseeyou-teacher"
  account = "885625664603"
  bucket  = "iseeyou-teacher-data-885625664603-eu-west-2"
}
resource "aws_s3_bucket" "data" {
  bucket        = local.bucket
  force_destroy = false
  lifecycle { prevent_destroy = true }
}
resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_ownership_controls" "data" {
  bucket = aws_s3_bucket.data.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_policy" "data" {
  bucket = aws_s3_bucket.data.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.data.arn, "${aws_s3_bucket.data.arn}/*"],
    Condition = { Bool = { "aws:SecureTransport" = "false" } }
  }] })
}
resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket     = aws_s3_bucket.data.id
  depends_on = [aws_s3_bucket_versioning.data]
  rule {
    id     = "raw-retention"
    status = "Enabled"
    filter { prefix = "raw/" }
    expiration { days = 7 }
    noncurrent_version_expiration { noncurrent_days = 1 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
  rule {
    id     = "candidate-retention"
    status = "Enabled"
    filter { prefix = "candidates/" }
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 1 }
  }
}
resource "aws_sqs_queue" "dead" {
  name                      = "${local.name}-dead"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600
}
resource "aws_sqs_queue" "samples" {
  name                       = "${local.name}-samples"
  sqs_managed_sse_enabled    = true
  visibility_timeout_seconds = 720
  message_retention_seconds  = 86400
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dead.arn, maxReceiveCount = 3 })
}
resource "aws_sqs_queue_policy" "samples" {
  queue_url = aws_sqs_queue.samples.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Principal = { Service = "s3.amazonaws.com" }, Action = "sqs:SendMessage", Resource = aws_sqs_queue.samples.arn,
    Condition = { ArnEquals = { "aws:SourceArn" = aws_s3_bucket.data.arn }, StringEquals = { "aws:SourceAccount" = local.account } }
  }] })
}
resource "aws_s3_bucket_notification" "samples" {
  bucket = aws_s3_bucket.data.id
  queue {
    queue_arn     = aws_sqs_queue.samples.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "raw/manifests/"
    filter_suffix = ".json"
  }
  depends_on = [aws_sqs_queue_policy.samples]
}
resource "aws_iam_role" "worker" {
  name               = "${local.name}-worker"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/lambda/${local.name}-worker"
  retention_in_days = 7
}
resource "aws_iam_role_policy" "worker" {
  role = aws_iam_role.worker.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = "s3:ListBucket", Resource = aws_s3_bucket.data.arn,
    Condition = { StringLike = { "s3:prefix" = "candidates/*" } } },
    { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Resource = aws_sqs_queue.samples.arn },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion"], Resource = "${aws_s3_bucket.data.arn}/raw/*" },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = "${aws_s3_bucket.data.arn}/candidates/*" },
    { Effect = "Allow", Action = ["bedrock:InvokeModel"], Resource = "arn:aws:bedrock:eu-west-2::foundation-model/${var.teacher_model_id}" },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.worker.arn}:*" }
  ] })
}
data "archive_file" "worker" {
  type        = "zip"
  source_file = "${path.module}/lambda/teacher.py"
  output_path = "${path.module}/.terraform/teacher.zip"
}
resource "aws_lambda_function" "worker" {
  function_name                  = "${local.name}-worker"
  role                           = aws_iam_role.worker.arn
  runtime                        = "python3.12"
  handler                        = "teacher.handler"
  filename                       = data.archive_file.worker.output_path
  source_code_hash               = data.archive_file.worker.output_base64sha256
  timeout                        = 120
  memory_size                    = 256
  reserved_concurrent_executions = 2
  environment { variables = { BUCKET = aws_s3_bucket.data.id, MODEL_ID = var.teacher_model_id } }
  depends_on = [aws_iam_role_policy.worker]
}
resource "aws_lambda_event_source_mapping" "samples" {
  enabled                 = var.model_access_ready
  event_source_arn        = aws_sqs_queue.samples.arn
  function_name           = aws_lambda_function.worker.arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]
  scaling_config { maximum_concurrency = 2 }
}
resource "aws_cloudwatch_metric_alarm" "dead" {
  alarm_name          = "${local.name}-dead-letter"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.dead.name }
}
output "data_bucket" { value = aws_s3_bucket.data.id }
output "worker_name" { value = aws_lambda_function.worker.function_name }
output "teacher_model" { value = var.teacher_model_id }

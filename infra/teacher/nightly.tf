resource "aws_cloudwatch_log_group" "review" {
  name              = "/aws/lambda/iseeyou-teacher-review"
  retention_in_days = 7
}
resource "aws_iam_role" "review" {
  name               = "iseeyou-teacher-review"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy" "review" {
  role = aws_iam_role.review.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = "s3:ListBucket", Resource = aws_s3_bucket.data.arn, Condition = { StringLike = { "s3:prefix" = "candidates/*" } } },
    { Effect = "Allow", Action = "s3:PutObject", Resource = "${aws_s3_bucket.data.arn}/reviews/*" },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.review.arn}:*" }
  ] })
}
resource "aws_lambda_function" "review" {
  function_name    = "iseeyou-teacher-review"
  role             = aws_iam_role.review.arn
  runtime          = "python3.12"
  handler          = "review.handler"
  filename         = data.archive_file.worker.output_path
  source_code_hash = data.archive_file.worker.output_base64sha256
  timeout          = 30
  memory_size      = 128
  environment { variables = { BUCKET = aws_s3_bucket.data.id } }
  depends_on = [aws_iam_role_policy.review]
}
resource "aws_iam_role" "nightly" {
  name               = "iseeyou-teacher-nightly"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "states.amazonaws.com" }, Action = "sts:AssumeRole", Condition = { StringEquals = { "aws:SourceAccount" = local.account } } }] })
}
resource "aws_iam_role_policy" "nightly" {
  role   = aws_iam_role.nightly.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.review.arn }] })
}
resource "aws_sfn_state_machine" "nightly" {
  name     = "iseeyou-teacher-nightly"
  role_arn = aws_iam_role.nightly.arn
  definition = jsonencode({ StartAt = "InventoryAndTrainingGate", States = {
    InventoryAndTrainingGate = { Type = "Task", Resource = "arn:aws:states:::lambda:invoke", Parameters = { FunctionName = aws_lambda_function.review.arn, Payload = {} }, OutputPath = "$.Payload", Retry = [{ ErrorEquals = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"], IntervalSeconds = 5, MaxAttempts = 2, BackoffRate = 2 }], End = true }
  } })
  depends_on = [aws_iam_role_policy.nightly]
}
resource "aws_cloudwatch_event_rule" "nightly" {
  name                = "iseeyou-teacher-nightly"
  description         = "Nightly candidate inventory; skips training until a verified dataset exists"
  schedule_expression = "cron(0 2 * * ? *)"
}
resource "aws_iam_role" "schedule" {
  name               = "iseeyou-teacher-schedule"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "events.amazonaws.com" }, Action = "sts:AssumeRole", Condition = { StringEquals = { "aws:SourceAccount" = local.account } } }] })
}
resource "aws_iam_role_policy" "schedule" {
  role   = aws_iam_role.schedule.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "states:StartExecution", Resource = aws_sfn_state_machine.nightly.arn }] })
}
resource "aws_cloudwatch_event_target" "nightly" {
  rule       = aws_cloudwatch_event_rule.nightly.name
  arn        = aws_sfn_state_machine.nightly.arn
  role_arn   = aws_iam_role.schedule.arn
  depends_on = [aws_iam_role_policy.schedule]
}
output "nightly_state_machine_arn" { value = aws_sfn_state_machine.nightly.arn }

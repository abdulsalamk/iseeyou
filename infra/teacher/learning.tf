data "external" "training_code" {
  program = ["python3", "${path.module}/package_training.py"]
  query = {
    source_hash = sha256(join("", [for file in sort(tolist(fileset("${path.module}/training", "**"))) : filesha256("${path.module}/training/${file}")]))
  }
}

resource "aws_s3_object" "training_code" {
  bucket                 = aws_s3_bucket.data.id
  key                    = "learning/code/training-code.tar.gz"
  source                 = data.external.training_code.result.path
  source_hash            = data.external.training_code.result.sha256
  server_side_encryption = "AES256"
  content_type           = "application/gzip"
}

resource "aws_s3_object" "baseline_checkpoint" {
  bucket                 = aws_s3_bucket.data.id
  key                    = "learning/baseline/yolo26n.pt"
  source                 = "${path.module}/../../models/yolo26n.pt"
  source_hash            = filebase64sha256("${path.module}/../../models/yolo26n.pt")
  server_side_encryption = "AES256"
  content_type           = "application/octet-stream"
}

resource "aws_iam_role" "training" {
  name               = "iseeyou-teacher-sagemaker-training"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "sagemaker.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}

resource "aws_iam_role_policy" "training" {
  role = aws_iam_role.training.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion"], Resource = ["${aws_s3_bucket.data.arn}/raw/*", "${aws_s3_bucket.data.arn}/candidates/*", "${aws_s3_bucket.data.arn}/learning/*"] },
    { Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.data.arn}/learning/models/*" },
    { Effect = "Allow", Action = ["dynamodb:UpdateItem"], Resource = aws_dynamodb_table.uploads.arn },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:CreateLogGroup"], Resource = "*" }
  ] })
}

resource "aws_iam_role" "learning" {
  name               = "iseeyou-teacher-learning"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}

resource "aws_cloudwatch_log_group" "learning" {
  name              = "/aws/lambda/iseeyou-teacher-learning"
  retention_in_days = 14
}

resource "aws_iam_role_policy" "learning" {
  role = aws_iam_role.learning.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.data.arn,
    Condition = { StringLike = { "s3:prefix" = ["candidates/*", "raw/manifests/*"] } } },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion"], Resource = ["${aws_s3_bucket.data.arn}/raw/*", "${aws_s3_bucket.data.arn}/candidates/*", "${aws_s3_bucket.data.arn}/learning/*"] },
    { Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.data.arn}/learning/*" },
    { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:UpdateItem"], Resource = aws_dynamodb_table.uploads.arn },
    { Effect = "Allow", Action = ["dynamodb:Query"], Resource = [aws_dynamodb_table.uploads.arn, "${aws_dynamodb_table.uploads.arn}/index/*"] },
    { Effect = "Allow", Action = ["sagemaker:CreateTrainingJob", "sagemaker:DescribeTrainingJob"], Resource = "*" },
    { Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = aws_lambda_function.worker.arn },
    { Effect = "Allow", Action = ["iam:PassRole"], Resource = aws_iam_role.training.arn,
    Condition = { StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" } } },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.learning.arn}:*" }
  ] })
}

resource "aws_lambda_function" "learning" {
  function_name                  = "iseeyou-teacher-learning"
  role                           = aws_iam_role.learning.arn
  runtime                        = "python3.12"
  handler                        = "learning.handler"
  filename                       = data.archive_file.worker.output_path
  source_code_hash               = data.archive_file.worker.output_base64sha256
  timeout                        = 120
  memory_size                    = 512
  reserved_concurrent_executions = 1
  environment { variables = {
    BUCKET                       = aws_s3_bucket.data.id
    TABLE                        = aws_dynamodb_table.uploads.id
    TRAINING_ROLE_ARN            = aws_iam_role.training.arn
    TRAINING_CODE_KEY            = aws_s3_object.training_code.key
    WORKER_FUNCTION              = aws_lambda_function.worker.function_name
    BASELINE_KEY                 = aws_s3_object.baseline_checkpoint.key
    TRAINING_IMAGE               = "763104351884.dkr.ecr.eu-west-2.amazonaws.com/pytorch-training:2.7.0-gpu-py311"
    TRAINING_INSTANCE            = "ml.g4dn.xlarge"
    TRAINING_MAX_RUNTIME_SECONDS = "900"
    TRAINING_EPOCHS              = "10"
    TRAIN_JOB_RESERVE_GBP        = "2.00"
    PIPELINE_SOFT_LIMIT_GBP      = "8.00"
    SESSION_WAIT_ATTEMPTS        = "120"
  } }
  depends_on = [aws_iam_role_policy.learning, aws_iam_role_policy.training]
}

resource "aws_iam_role" "learning_state_machine" {
  name               = "iseeyou-teacher-learning-states"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "states.amazonaws.com" }, Action = "sts:AssumeRole", Condition = { StringEquals = { "aws:SourceAccount" = local.account } } }] })
}

resource "aws_iam_role_policy" "learning_state_machine" {
  role = aws_iam_role.learning_state_machine.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = aws_lambda_function.learning.arn }
  ] })
}

resource "aws_sfn_state_machine" "learning" {
  name     = "iseeyou-teacher-learning"
  role_arn = aws_iam_role.learning_state_machine.arn
  definition = jsonencode({
    StartAt = "CheckSession"
    States = {
      CheckSession = {
        Type       = "Task", Resource = "arn:aws:states:::lambda:invoke",
        Parameters = { FunctionName = aws_lambda_function.learning.arn, Payload = { "session_id.$" = "$.session_id", "attempt.$" = "$.attempt" } },
        OutputPath = "$.Payload", Next = "WaitForNova"
      }
      WaitForNova      = { Type = "Choice", Choices = [{ Variable = "$.wait", BooleanEquals = true, Next = "Pause" }], Default = "Finished" }
      Pause            = { Type = "Wait", Seconds = 60, Next = "IncrementAttempt" }
      IncrementAttempt = { Type = "Pass", Parameters = { "session_id.$" = "$.session_id", "attempt.$" = "States.MathAdd($.attempt, 1)" }, Next = "CheckSession" }
      Finished         = { Type = "Succeed" }
    }
  })
  depends_on = [aws_iam_role_policy.learning_state_machine]
}

resource "aws_lambda_permission" "learning_state_machine" {
  statement_id  = "AllowLearningStateMachine"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.learning.function_name
  principal     = "states.amazonaws.com"
  source_arn    = aws_sfn_state_machine.learning.arn
}

resource "aws_cloudwatch_log_group" "job_events" {
  name              = "/aws/lambda/iseeyou-teacher-job-events"
  retention_in_days = 14
}

resource "aws_iam_role" "job_events" {
  name               = "iseeyou-teacher-job-events"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}

resource "aws_iam_role_policy" "job_events" {
  role = aws_iam_role.job_events.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"], Resource = aws_dynamodb_table.uploads.arn },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.job_events.arn}:*" }
  ] })
}

resource "aws_lambda_function" "job_events" {
  function_name    = "iseeyou-teacher-job-events"
  role             = aws_iam_role.job_events.arn
  runtime          = "python3.12"
  handler          = "job_events.handler"
  filename         = data.archive_file.worker.output_path
  source_code_hash = data.archive_file.worker.output_base64sha256
  timeout          = 30
  memory_size      = 128
  environment { variables = { TABLE = aws_dynamodb_table.uploads.id } }
  depends_on = [aws_iam_role_policy.job_events]
}

resource "aws_cloudwatch_event_rule" "training_events" {
  name          = "iseeyou-teacher-training-events"
  description   = "Track terminal status for private YOLO shadow-training jobs"
  event_pattern = jsonencode({ source = ["aws.sagemaker"], "detail-type" = ["SageMaker Training Job State Change"], detail = { TrainingJobStatus = ["Completed", "Failed", "Stopped"] } })
}

resource "aws_cloudwatch_event_target" "training_events" {
  rule      = aws_cloudwatch_event_rule.training_events.name
  target_id = "teacher-training-status"
  arn       = aws_lambda_function.job_events.arn
}

resource "aws_lambda_permission" "training_events" {
  statement_id  = "AllowSageMakerEvents"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.job_events.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.training_events.arn
}

resource "aws_sns_topic" "learning_budget" {
  name = "iseeyou-teacher-learning-budget"
}

resource "aws_budgets_budget" "learning" {
  name        = "iseeyou-teacher-learning-monthly"
  budget_type = "COST"
  # The linked AWS account accepts USD budgets only. $12 is intentionally
  # below £10 at the 24 Oct 2026 reference rate; the internal £8 ledger is the
  # workflow's primary guardrail and absorbs FX/billing delay headroom.
  limit_amount = "12"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name   = "Service"
    values = ["Amazon Bedrock", "Amazon SageMaker", "Amazon Simple Storage Service", "AWS Lambda", "Amazon DynamoDB", "Amazon Simple Queue Service", "AWS Step Functions", "Amazon API Gateway"]
  }
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.learning_budget.arn]
  }
}

resource "aws_iam_policy" "learning_budget_stop" {
  name   = "iseeyou-teacher-learning-budget-stop"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Deny", Action = ["bedrock:InvokeModel", "sagemaker:CreateTrainingJob"], Resource = "*" }] })
}

resource "aws_iam_role" "budget_action" {
  name               = "iseeyou-teacher-budget-action"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "budgets.amazonaws.com" }, Action = "sts:AssumeRole", Condition = { StringEquals = { "aws:SourceAccount" = local.account } } }] })
}

resource "aws_iam_role_policy" "budget_action" {
  role   = aws_iam_role.budget_action.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"], Resource = [aws_iam_role.worker.arn, aws_iam_role.learning.arn] }] })
}

resource "aws_budgets_budget_action" "learning_stop" {
  budget_name        = aws_budgets_budget.learning.name
  action_type        = "APPLY_IAM_POLICY"
  approval_model     = "AUTOMATIC"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budget_action.arn
  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = 80
  }
  definition {
    iam_action_definition {
      policy_arn = aws_iam_policy.learning_budget_stop.arn
      roles      = [aws_iam_role.worker.name, aws_iam_role.learning.name]
    }
  }
  subscriber {
    address           = aws_sns_topic.learning_budget.arn
    subscription_type = "SNS"
  }
  depends_on = [aws_iam_role_policy.budget_action]
}

resource "aws_cloudwatch_log_group" "budget_reset" {
  name              = "/aws/lambda/iseeyou-teacher-budget-reset"
  retention_in_days = 14
}

resource "aws_iam_role" "budget_reset" {
  name               = "iseeyou-teacher-budget-reset"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}

resource "aws_iam_role_policy" "budget_reset" {
  role = aws_iam_role.budget_reset.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["iam:DetachRolePolicy"], Resource = [aws_iam_role.worker.arn, aws_iam_role.learning.arn] },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.budget_reset.arn}:*" }
  ] })
}

resource "aws_lambda_function" "budget_reset" {
  function_name    = "iseeyou-teacher-budget-reset"
  role             = aws_iam_role.budget_reset.arn
  runtime          = "python3.12"
  handler          = "budget_reset.handler"
  filename         = data.archive_file.worker.output_path
  source_code_hash = data.archive_file.worker.output_base64sha256
  timeout          = 30
  memory_size      = 128
  environment { variables = { BUDGET_POLICY_ARN = aws_iam_policy.learning_budget_stop.arn, WORKER_ROLE_NAME = aws_iam_role.worker.name, LEARNING_ROLE_NAME = aws_iam_role.learning.name } }
  depends_on = [aws_iam_role_policy.budget_reset]
}

resource "aws_cloudwatch_event_rule" "budget_reset" {
  name                = "iseeyou-teacher-budget-monthly-reset"
  description         = "Remove last month's learning budget deny at the start of a new month"
  schedule_expression = "cron(5 0 1 * ? *)"
}

resource "aws_cloudwatch_event_target" "budget_reset" {
  rule      = aws_cloudwatch_event_rule.budget_reset.name
  target_id = "teacher-budget-reset"
  arn       = aws_lambda_function.budget_reset.arn
}

resource "aws_lambda_permission" "budget_reset" {
  statement_id  = "AllowMonthlyBudgetReset"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.budget_reset.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.budget_reset.arn
}

output "learning_state_machine_arn" { value = aws_sfn_state_machine.learning.arn }

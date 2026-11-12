terraform {
  required_version = ">= 1.10"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
  backend "s3" {
    bucket       = "tfstate-186961531503-lab"
    key          = "lab/security.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { Project = "prisma-aws-lab", Owner = "sriram", ManagedBy = "terraform" }
  }
}

variable "alert_email" { type = string }

data "aws_caller_identity" "me" {}

locals {
  account_id = data.aws_caller_identity.me.account_id
}

# ---------- CloudTrail trail (EventBridge needs one to receive API call events) ----------
resource "aws_s3_bucket" "trail" {
  #checkov:skip=CKV_AWS_144:No replication needed for lab logs
  #checkov:skip=CKV_AWS_18:This is the log bucket itself
  #checkov:skip=CKV2_AWS_62:No event notifications needed
  #checkov:skip=CKV2_AWS_61:Short-lived lab, no lifecycle rules
  #checkov:skip=CKV_AWS_145:SSE-S3 instead of KMS to stay in the free tier
  bucket        = "lab-cloudtrail-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id
  versioning_configuration { status = "Enabled" }
}

#trivy:ignore:AVD-AWS-0132 SSE-S3 instead of a customer-managed KMS key to stay in the free tier
resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail_bucket.json
}

#trivy:ignore:AVD-AWS-0162 CloudWatch Logs delivery not needed for the lab; EventBridge handles alerting
#trivy:ignore:AVD-AWS-0015 SSE-S3 instead of KMS to stay in the free tier
resource "aws_cloudtrail" "lab" {
  #checkov:skip=CKV_AWS_35:SSE-S3 instead of KMS to stay in the free tier
  #checkov:skip=CKV_AWS_252:Alerts go through EventBridge, not trail SNS
  #checkov:skip=CKV2_AWS_10:CloudWatch Logs delivery not needed for the lab
  name                          = "lab-trail"
  s3_bucket_name                = aws_s3_bucket.trail.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  depends_on                    = [aws_s3_bucket_policy.trail]
}

# ---------- SNS topic and email ----------
#trivy:ignore:AVD-AWS-0136 AWS-managed SNS key is enough for lab alerts; a CMK (~$1/month) would be used in production
resource "aws_sns_topic" "alerts" {
  name = "lab-security-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------- Lambda and its least-privilege role ----------
resource "aws_iam_role" "alert" {
  name = "lab-alert-lambda"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.alert.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "publish" {
  name = "publish-alerts"
  role = aws_iam_role.alert.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sns:Publish", Resource = aws_sns_topic.alerts.arn }]
  })
}

data "archive_file" "alert" {
  type        = "zip"
  source_file = "${path.module}/lambda/alert.py"
  output_path = "${path.module}/alert.zip"
}

resource "aws_lambda_function" "alert" {
  #checkov:skip=CKV_AWS_50:X-Ray tracing not needed for the lab
  #checkov:skip=CKV_AWS_115:No reserved concurrency needed at lab volume
  #checkov:skip=CKV_AWS_116:No DLQ; EventBridge retries are enough here
  #checkov:skip=CKV_AWS_117:Only calls SNS, no VPC resources
  #checkov:skip=CKV_AWS_173:Env var holds only a topic ARN, not a secret
  #checkov:skip=CKV_AWS_272:Code signing out of scope for the lab
  function_name    = "lab-security-alert"
  role             = aws_iam_role.alert.arn
  runtime          = "python3.12"
  handler          = "alert.lambda_handler"
  filename         = data.archive_file.alert.output_path
  source_code_hash = data.archive_file.alert.output_base64sha256
  timeout          = 10
  environment {
    variables = { TOPIC_ARN = aws_sns_topic.alerts.arn }
  }
}

# ---------- EventBridge rules ----------
resource "aws_cloudwatch_event_rule" "sg_ingress" {
  name = "lab-sg-ingress"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["AuthorizeSecurityGroupIngress"]
    }
  })
}

resource "aws_cloudwatch_event_rule" "root_login" {
  name = "lab-root-login"
  event_pattern = jsonencode({
    "detail-type" = ["AWS Console Sign In via CloudTrail"]
    detail        = { userIdentity = { type = ["Root"] } }
  })
}

locals {
  rules = {
    sg   = aws_cloudwatch_event_rule.sg_ingress
    root = aws_cloudwatch_event_rule.root_login
  }
}

resource "aws_cloudwatch_event_target" "alert" {
  for_each = local.rules
  rule     = each.value.name
  arn      = aws_lambda_function.alert.arn
}

resource "aws_lambda_permission" "events" {
  for_each      = local.rules
  statement_id  = "allow-eventbridge-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alert.function_name
  principal     = "events.amazonaws.com"
  source_arn    = each.value.arn
}
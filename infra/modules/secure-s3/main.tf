variable "bucket_name" { type = string }

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "this" {
  description             = "Key for ${var.bucket_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AccountAdmin"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
}

#trivy:ignore:AVD-AWS-0089 Access logging covered by the CloudTrail trail in Phase 7
resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV_AWS_144:Cross-region replication not needed for lab data
  #checkov:skip=CKV_AWS_18:Access logging covered by the CloudTrail trail in Phase 7
  #checkov:skip=CKV2_AWS_62:No event notifications needed for this bucket
  #checkov:skip=CKV2_AWS_61:Lifecycle rules not needed for a short-lived lab bucket
  bucket        = var.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.this.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration { status = "Enabled" }
}

output "bucket_arn" { value = aws_s3_bucket.this.arn }
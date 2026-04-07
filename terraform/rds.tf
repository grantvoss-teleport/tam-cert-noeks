# ─── S3 Bucket for Teleport Session Recordings ───────────────────────────────

resource "aws_s3_bucket" "teleport_sessions" {
  bucket        = "${var.training_prefix}-teleport-sessions"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-teleport-sessions"
  })
}

resource "aws_s3_bucket_versioning" "teleport_sessions" {
  bucket = aws_s3_bucket.teleport_sessions.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "teleport_sessions" {
  bucket = aws_s3_bucket.teleport_sessions.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "teleport_sessions" {
  bucket                  = aws_s3_bucket.teleport_sessions.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─── S3 session recordings access ────────────────────────────────────────────

resource "aws_iam_role_policy" "s3_sessions" {
  name = "${var.training_prefix}-s3-sessions-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:ListBucketVersions",
        "s3:ListBucketMultipartUploads",
        "s3:CreateMultipartUpload",
        "s3:UploadPart",
        "s3:CompleteMultipartUpload",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ]
      Resource = [
        aws_s3_bucket.teleport_sessions.arn,
        "${aws_s3_bucket.teleport_sessions.arn}/*"
      ]
    }]
  })
}

# ─── Teleport license secret ──────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "teleport_license" {
  name                    = "${var.training_prefix}/teleport/license"
  recovery_window_in_days = 0

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-teleport-license"
  })
}

resource "aws_secretsmanager_secret_version" "teleport_license" {
  secret_id     = aws_secretsmanager_secret.teleport_license.id
  secret_string = var.teleport_license
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "sessions_bucket" {
  value       = aws_s3_bucket.teleport_sessions.bucket
  description = "S3 bucket for Teleport session recordings"
}

# ─── Identity Activity Center Infrastructure ─────────────────────────────────
# Supports Teleport Access Graph Identity Activity Center.
# Resources: KMS key, long-term S3 bucket, transient S3 bucket,
#            AWS Glue database + table, Amazon Athena workgroup,
#            IAM permissions for the EC2 role.

data "aws_caller_identity" "current" {}

data "aws_sqs_queue" "identity_activity" {
  name = "grantvoss-q-1"
}

# ── KMS key for encrypting S3 objects and SQS messages ───────────────────────

resource "aws_kms_key" "identity_activity" {
  description             = "${var.training_prefix} Identity Activity Center encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow EC2 Role"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.ec2.arn
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        # S3 must encrypt messages it sends to the KMS-encrypted SQS queue.
        Sid    = "AllowS3ForEncryptedSQS"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-identity-activity-kms"
  })
}

resource "aws_kms_alias" "identity_activity" {
  name          = "alias/${var.training_prefix}-identity-activity"
  target_key_id = aws_kms_key.identity_activity.key_id
}

# ── Long-term S3 bucket (Parquet audit event storage) ─────────────────────────

resource "aws_s3_bucket" "identity_activity_long" {
  bucket        = "${var.training_prefix}-identity-activity-long"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-identity-activity-long"
  })
}

resource "aws_s3_bucket_versioning" "identity_activity_long" {
  bucket = aws_s3_bucket.identity_activity_long.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "identity_activity_long" {
  bucket = aws_s3_bucket.identity_activity_long.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.identity_activity.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_ownership_controls" "identity_activity_long" {
  bucket = aws_s3_bucket.identity_activity_long.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "identity_activity_long" {
  bucket                  = aws_s3_bucket.identity_activity_long.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── Transient S3 bucket (Athena query results + large files) ──────────────────

resource "aws_s3_bucket" "identity_activity_transient" {
  bucket        = "${var.training_prefix}-identity-activity-transient"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-identity-activity-transient"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "identity_activity_transient" {
  bucket = aws_s3_bucket.identity_activity_transient.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.identity_activity.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_ownership_controls" "identity_activity_transient" {
  bucket = aws_s3_bucket.identity_activity_transient.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "identity_activity_transient" {
  bucket                  = aws_s3_bucket.identity_activity_transient.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "identity_activity_transient" {
  bucket = aws_s3_bucket.identity_activity_transient.id
  rule {
    id     = "expire-transient-objects"
    status = "Enabled"
    expiration {
      days = 60
    }
    filter {}
  }
}

# ── SQS queues ───────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "identity_activity_dlq" {
  name                              = "${var.training_prefix}-identity-activity-dlq"
  kms_master_key_id                 = aws_kms_key.identity_activity.arn
  kms_data_key_reuse_period_seconds = 300
  message_retention_seconds         = 604800 # 7 days

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-identity-activity-dlq"
  })
}

resource "aws_sqs_queue" "identity_activity" {
  name                              = "${var.training_prefix}-identity-activity"
  kms_master_key_id                 = aws_kms_key.identity_activity.arn
  kms_data_key_reuse_period_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.identity_activity_dlq.arn
    maxReceiveCount     = 20
  })

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-identity-activity"
  })
}

resource "aws_sqs_queue_policy" "identity_activity" {
  queue_url = aws_sqs_queue.identity_activity.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2Role"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.ec2.arn
        }
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = aws_sqs_queue.identity_activity.arn
      },
      {
        Sid    = "AllowS3Notification"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.identity_activity.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = aws_s3_bucket.identity_activity_long.arn
          }
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# ── S3 event notification → SQS ───────────────────────────────────────────────
# Triggers an SQS message for each new Parquet file written to the long-term
# bucket so Access Graph can register the partition in the Glue catalog.

resource "aws_s3_bucket_notification" "identity_activity_long" {
  bucket = aws_s3_bucket.identity_activity_long.id

  queue {
    queue_arn     = aws_sqs_queue.identity_activity.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".parquet"
  }

  depends_on = [aws_sqs_queue_policy.identity_activity]
}

# ── AWS Glue catalog ──────────────────────────────────────────────────────────

resource "aws_glue_catalog_database" "identity_activity" {
  name        = "${var.training_prefix}-identity-activity"
  description = "Teleport Identity Activity Center audit event catalog"
}

# Partition projection eliminates manual MSCK REPAIR TABLE — Athena resolves
# tenant_id (injected) and event_date (daily range) partitions automatically.
resource "aws_glue_catalog_table" "identity_activity" {
  name          = "${var.training_prefix}-audit-events"
  database_name = aws_glue_catalog_database.identity_activity.name
  table_type    = "EXTERNAL_TABLE"
  description   = "Teleport Identity Activity Center audit events"

  parameters = {
    "EXTERNAL"            = "TRUE"
    "classification"      = "parquet"
    "parquet.compression" = "SNAPPY"

    "projection.enabled" = "true"

    "projection.tenant_id.type" = "injected"

    "projection.event_date.type"          = "date"
    "projection.event_date.format"        = "yyyy-MM-dd"
    "projection.event_date.interval"      = "1"
    "projection.event_date.interval.unit" = "DAYS"
    "projection.event_date.range"         = "NOW-4YEARS,NOW"

    "storage.location.template" = "s3://${aws_s3_bucket.identity_activity_long.bucket}/data/$${tenant_id}/$${event_date}/"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.identity_activity_long.bucket}/data/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns { name = "event_source"        type = "string" }
    columns { name = "identity"            type = "string" }
    columns { name = "identity_kind"       type = "string" }
    columns { name = "identity_id"         type = "string" }
    columns { name = "token"               type = "string" }
    columns { name = "action"              type = "string" }
    columns { name = "origin"              type = "string" }
    columns { name = "status"              type = "string" }
    columns { name = "ip"                  type = "string" }
    columns { name = "city"                type = "string" }
    columns { name = "country"             type = "string" }
    columns { name = "region"              type = "string" }
    columns { name = "latitude"            type = "double" }
    columns { name = "longitude"           type = "double" }
    columns { name = "target_resource"     type = "string" }
    columns { name = "target_kind"         type = "string" }
    columns { name = "target_location"     type = "string" }
    columns { name = "target_id"           type = "string" }
    columns { name = "user_agent"          type = "string" }
    columns { name = "event_type"          type = "string" }
    columns { name = "event_time"          type = "timestamp" }
    columns { name = "uid"                 type = "string" }
    columns { name = "event_data"          type = "string" }
    columns { name = "aws_account_id"      type = "string" }
    columns { name = "aws_service"         type = "string" }
    columns { name = "github_organization" type = "string" }
    columns { name = "github_repo"         type = "string" }
    columns { name = "okta_org"            type = "string" }
    columns { name = "teleport_cluster"    type = "string" }
  }

  partition_keys {
    name = "tenant_id"
    type = "string"
  }

  partition_keys {
    name = "event_date"
    type = "date"
  }
}

# ── Amazon Athena workgroup ───────────────────────────────────────────────────

resource "aws_athena_workgroup" "identity_activity" {
  name        = "${var.training_prefix}-identity-activity"
  description = "Teleport Identity Activity Center query workgroup"
  force_destroy = true

  configuration {
    bytes_scanned_cutoff_per_query = 21474836480 # 20 GB — prevents runaway query costs

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${aws_s3_bucket.identity_activity_transient.bucket}/results/"
      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = aws_kms_key.identity_activity.arn
      }
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-identity-activity"
  })
}

# ── IAM permissions for Identity Activity Center ──────────────────────────────

resource "aws_iam_role_policy" "identity_activity" {
  name = "${var.training_prefix}-identity-activity-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3LongTermBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
          "s3:ListBucketVersions"
        ]
        Resource = aws_s3_bucket.identity_activity_long.arn
      },
      {
        Sid    = "S3LongTermObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = "${aws_s3_bucket.identity_activity_long.arn}/data/*"
      },
      {
        Sid    = "S3TransientBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
          "s3:ListBucketVersions"
        ]
        Resource = aws_s3_bucket.identity_activity_transient.arn
      },
      {
        Sid    = "S3TransientObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = [
          "${aws_s3_bucket.identity_activity_transient.arn}/results/*",
          "${aws_s3_bucket.identity_activity_transient.arn}/large_files/*"
        ]
      },
      {
        Sid    = "GlueAccess"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable"
        ]
        Resource = [
          "arn:aws:glue:us-west-2:${data.aws_caller_identity.current.account_id}:catalog",
          aws_glue_catalog_database.identity_activity.arn,
          aws_glue_catalog_table.identity_activity.arn
        ]
      },
      {
        Sid    = "AthenaAccess"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup"
        ]
        Resource = aws_athena_workgroup.identity_activity.arn
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.identity_activity.arn
      },
      {
        Sid    = "SQSAccess"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = aws_sqs_queue.identity_activity.arn
      }
    ]
  })
}

# ─── Identity Activity Center Outputs ────────────────────────────────────────

output "identity_activity_long_bucket" {
  value       = aws_s3_bucket.identity_activity_long.bucket
  description = "S3 bucket for Identity Activity Center long-term storage"
}

output "identity_activity_transient_bucket" {
  value       = aws_s3_bucket.identity_activity_transient.bucket
  description = "S3 bucket for Identity Activity Center transient storage"
}

output "identity_activity_kms_arn" {
  value       = aws_kms_key.identity_activity.arn
  description = "KMS key ARN for Identity Activity Center"
}

output "identity_activity_workgroup" {
  value       = aws_athena_workgroup.identity_activity.name
  description = "Athena workgroup for Identity Activity Center"
}

output "identity_activity_sqs_queue_url" {
  value       = aws_sqs_queue.identity_activity.url
  description = "SQS queue URL for Identity Activity Center"
}

output "identity_activity_sqs_dlq_url" {
  value       = aws_sqs_queue.identity_activity_dlq.url
  description = "SQS dead-letter queue URL for Identity Activity Center"
}

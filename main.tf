terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }

    time = {
      source  = "hashicorp/time"
    }
    null = {
      source  = "hashicorp/null"
    }
  }
  backend "s3" {}
}

locals {
    today  = timestamp()
    lariat_vendor_tag_aws = var.lariat_vendor_tag_aws != "" ? var.lariat_vendor_tag_aws : "lariat-${var.aws_region}"
    flattened_bucket_prefixes_sns = flatten([
      for bucket, inner_map in var.existing_s3_bucket_notifications_sns : [
        for prefix, topic in inner_map : {
          bucket = bucket
          prefix = prefix
          topic = topic
        }
      ]
    ])

    flattened_bucket_prefixes_lambda = flatten([
      for bucket, inner_map in var.existing_s3_bucket_notifications_lambda : [
        for prefix, func in inner_map : {
          bucket = bucket
          prefix = prefix
          func = func
        }
      ]
    ])
}

# Configure default the AWS Provider
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      VendorLariat = local.lariat_vendor_tag_aws
    }
  }
}

data "aws_caller_identity" "current" {}

// Create object for agent configuration file in s3
resource "aws_s3_bucket" "lariat_s3_agent_config_bucket" {
  bucket_prefix = var.s3_agent_config_bucket
  force_destroy = true
}

resource "aws_s3_object" "lariat_s3_agent_config" {
  bucket = aws_s3_bucket.lariat_s3_agent_config_bucket.bucket
  key    = "s3_agent.yaml"
  source = "s3_agent.yaml"

  etag = filemd5("s3_agent.yaml")
}


// Policy document for s3 agent lambda to access its execution image
data "aws_iam_policy_document" "lariat_s3_agent_repository_policy" {
  statement {
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeRepositories",
      "ecr:GetRepositoryPolicy",
      "ecr:ListImages",
      "ecr:DeleteRepository",
      "ecr:BatchDeleteImage",
      "ecr:SetRepositoryPolicy",
      "ecr:DeleteRepositoryPolicy"
    ]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda-assume-role-policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "lariat_s3_monitoring_policy" {
  name_prefix = "lariat-s3-monitoring-policy"
  policy = templatefile("iam/lariat-s3-monitoring-policy.json.tftpl", { s3_buckets = var.target_s3_buckets, s3_agent_config_bucket = aws_s3_bucket.lariat_s3_agent_config_bucket.bucket })
}

resource "aws_iam_role" "lariat_s3_monitoring_lambda_role" {
  name_prefix = "lariat-s3-monitoring-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda-assume-role-policy.json
  managed_policy_arns = [aws_iam_policy.lariat_s3_monitoring_policy.arn, "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"]
}

resource "aws_lambda_function" "lariat_s3_monitoring_lambda" {
  function_name = "lariat-s3-monitoring-lambda"
  image_uri = "358681817243.dkr.ecr.${var.aws_region}.amazonaws.com/lariat-s3-agent:latest"
  role = aws_iam_role.lariat_s3_monitoring_lambda_role.arn
  package_type = "Image"
  memory_size = 10240
  timeout = 900

  environment {
    variables = {
      LARIAT_API_KEY = var.lariat_api_key
      LARIAT_APPLICATION_KEY = var.lariat_application_key
      LARIAT_PAYLOAD_SOURCE = var.lariat_payload_source
      S3_AGENT_CONFIG_PATH = "${aws_s3_bucket.lariat_s3_agent_config_bucket.bucket}/s3_agent.yaml"
      CLOUD_AGENT_CONFIG_PATH = "${aws_s3_bucket.lariat_s3_agent_config_bucket.bucket}/s3_agent.yaml"
      LARIAT_ENDPOINT = "http://ingest.lariatdata.com/api"
      LARIAT_OUTPUT_BUCKET = "lariat-batch-agent-sink"
      LARIAT_SINK_AWS_ACCESS_KEY_ID = "${var.lariat_sink_aws_access_key_id}"
      LARIAT_SINK_AWS_SECRET_ACCESS_KEY = "${var.lariat_sink_aws_secret_access_key}"
      LARIAT_CLOUD_ACCOUNT_ID = "${data.aws_caller_identity.current.account_id}"
    }
  }
}

data "aws_iam_policy_document" "allow_config_access_from_lariat_account" {
  statement {
    principals {
      type        = "AWS"
      identifiers = ["358681817243",
      "arn:aws:sts::358681817243:assumed-role/lariat-iam-terraform-cross-account-access-role-${data.aws_caller_identity.current.account_id}/s3-session-${data.aws_caller_identity.current.account_id}"]
    }

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]

    resources = [
      aws_s3_bucket.lariat_s3_agent_config_bucket.arn,
      "${aws_s3_bucket.lariat_s3_agent_config_bucket.arn}/*",
    ]
  }
}

resource "aws_s3_bucket_policy" "allow_config_access_from_lariat_account_policy" {
  bucket = aws_s3_bucket.lariat_s3_agent_config_bucket.id
  policy = data.aws_iam_policy_document.allow_config_access_from_lariat_account.json
}

// s3 object created trigger for lambda
data "aws_s3_bucket" "lariat_monitored_s3_buckets" {
  for_each = toset(var.target_s3_buckets)
  bucket = each.key
}

data "aws_iam_policy_document" "lariat_monitoring_sns_iam" {
  count = length(var.target_s3_bucket_prefixes) > 0 ? 1 : 0

  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.lariat_s3_monitoring_events_topic[count.index].arn]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = values({
        for key, obj in data.aws_s3_bucket.lariat_monitored_s3_buckets : key => obj.arn
      })
    }
  }
}

data "aws_lambda_function" "existing_lambda_targets" {
  for_each = { for idx, entry in local.flattened_bucket_prefixes_lambda : idx => entry }
  function_name = each.value.func
}

data "aws_iam_role" "existing_lambda_roles" {
  for_each = { for idx, entry in local.flattened_bucket_prefixes_lambda : idx => entry }
  name = split("/", data.aws_lambda_function.existing_lambda_targets[each.key].role)[length(split("/", data.aws_lambda_function.existing_lambda_targets[each.key].role)) -1]
}

resource "aws_iam_policy" "allow_user_lambda_to_invoke_monitoring_policy" {
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "lambda:InvokeFunction",
        ]
        Effect   = "Allow"
        Resource = aws_lambda_function.lariat_s3_monitoring_lambda.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "existing_lambda_roles_policy_attachment" {
  for_each = { for idx, entry in local.flattened_bucket_prefixes_lambda : idx => entry }
  role = data.aws_iam_role.existing_lambda_roles[each.key].id
  policy_arn = aws_iam_policy.allow_user_lambda_to_invoke_monitoring_policy.arn
}

resource "aws_sns_topic" "lariat_s3_monitoring_events_topic" {
  count = length(var.target_s3_bucket_prefixes) > 0 ? 1 : 0
  name = "lariat-s3-monitoring-events"
}

resource "aws_sns_topic_policy" "lariat_s3_monitoring_events_topic_policy" {
  count = length(var.target_s3_bucket_prefixes) > 0 ? 1 : 0

  arn = aws_sns_topic.lariat_s3_monitoring_events_topic[count.index].arn
  policy = data.aws_iam_policy_document.lariat_monitoring_sns_iam[count.index].json
}

resource "aws_s3_bucket_notification" "lariat_s3_sns_notification" {
  for_each = var.target_s3_bucket_prefixes
  bucket = each.key

  dynamic "topic" {
    for_each = toset(each.value)
    content {
      topic_arn = aws_sns_topic.lariat_s3_monitoring_events_topic[0].arn
      events    = ["s3:ObjectCreated:*"]
      filter_prefix = topic.value
    }
  }
}

resource "aws_sns_topic_subscription" "lariat_sns_lambda_subscription" {
  count = length(var.target_s3_bucket_prefixes) > 0 ? 1 : 0

  topic_arn = aws_sns_topic.lariat_s3_monitoring_events_topic[count.index].arn
  protocol = "lambda"
  endpoint = aws_lambda_function.lariat_s3_monitoring_lambda.arn
}

resource "aws_sns_topic_subscription" "lariat_sns_lambda_subscription_existing" {
  for_each = { for idx, entry in local.flattened_bucket_prefixes_sns : idx => entry }

  topic_arn = each.value.topic
  protocol = "lambda"
  endpoint = aws_lambda_function.lariat_s3_monitoring_lambda.arn
}

resource "aws_lambda_permission" "sns_lambda_invoke_permission" {
  count = length(var.target_s3_bucket_prefixes) > 0 ? 1 : 0
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lariat_s3_monitoring_lambda.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.lariat_s3_monitoring_events_topic[count.index].arn
}

resource "aws_lambda_permission" "sns_lambda_invoke_permission_existing" {
  for_each = { for idx, entry in local.flattened_bucket_prefixes_sns : idx => entry }

  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lariat_s3_monitoring_lambda.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = each.value.topic
}

resource "aws_lambda_function_event_invoke_config" "lambda_destination_config" {
  for_each = { for idx, entry in local.flattened_bucket_prefixes_lambda : idx => entry }
  function_name = each.value.func
  destination_config {
    on_success {
      destination = aws_lambda_function.lariat_s3_monitoring_lambda.arn
    }
  }
}

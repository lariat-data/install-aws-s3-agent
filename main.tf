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

// Create object for agent configuration file in s3
resource "aws_s3_bucket" "lariat_athena_agent_config_bucket" {
  bucket_prefix = var.s3_agent_config_bucket
  force_destroy = true
}

resource "aws_s3_object" "lariat_athena_agent_config" {
  bucket = aws_s3_bucket.lariat_s3_agent_config_bucket.bucket
  key    = "athena_agent.yaml"
  source = "athena_agent.yaml"

  etag = filemd5("athena_agent.yaml")
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

resource "aws_lambda_function" "lariat_snowflake_monitoring_lambda" {
  function_name = "lariat-s3-monitoring-lambda"
  image_uri = "358681817243.dkr.ecr.${var.aws_region}.amazonaws.com/lariat-s3-agent:latest"
  role = aws_iam_role.lariat_s3_monitoring_lambda_role.arn
  package_type = "Image"
  memory_size = 512
  timeout = 900

  tags = {
    VendorLariat = local.lariat_vendor_tag_aws
  }

  environment {
    variables = {
      S3_QUERY_RESULTS_BUCKET = aws_s3_bucket.lariat_snowflake_query_results_bucket.bucket
      LARIAT_API_KEY = var.lariat_api_key
      LARIAT_APPLICATION_KEY = var.lariat_application_key
      S3_AGENT_CONFIG_PATH = "${aws_s3_bucket.lariat_snowflake_agent_config_bucket.bucket}/s3_agent.yaml"
      CLOUD_AGENT_CONFIG_PATH = "${aws_s3_bucket.lariat_snowflake_agent_config_bucket.bucket}/s3_agent.yaml"
      LARIAT_ENDPOINT = "http://ingest.lariatdata.com/api"
      LARIAT_OUTPUT_BUCKET = "lariat-batch-agent-sink"

      LARIAT_SINK_AWS_ACCESS_KEY_ID = "${var.lariat_sink_aws_access_key_id}"
      LARIAT_SINK_AWS_SECRET_ACCESS_KEY = "${var.lariat_sink_aws_secret_access_key}"

      LARIAT_CLOUD_ACCOUNT_ID = "${data.aws_caller_identity.current.account_id}"
    }
  }
}

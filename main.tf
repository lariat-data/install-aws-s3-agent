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

resource "aws_ecr_repository" "lariat_s3_agent_repository" {
  name = "lariat-s3-agent"
}

resource "aws_ecr_repository_policy" "lariat_s3_agent_repo_policy" {
  repository = aws_ecr_repository.lariat_s3_agent_repository.name
  policy = data.aws_iam_policy_document.lariat_athena_agent_repository_policy.json
}

variable "lariat_api_key" {
  type = string
}

variable "lariat_application_key" {
  type = string
}

variable "lariat_sink_aws_access_key_id" {
  type = string
}

variable "lariat_sink_aws_secret_access_key" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "target_s3_buckets" {
  type = list(string)
}

variable "target_s3_bucket_prefixes" {
  type = map(list(string))
}

variable "existing_s3_bucket_notifications_sns" {
  type = map(map(string))
}

variable "existing_s3_bucket_notifications_lambda" {
  type = map(map(string))
}

variable "backfill_interval_cron" {
  type = string
  default = "rate(45 minutes)"
}

variable "s3_agent_config_bucket" {
  type = string
  default = "lariat-s3-default-config"
}

variable "lariat_vendor_tag_aws" {
  type = string
  default = ""
}

variable "lariat_ecr_image_name" {
  type = string
  default = "lariat-s3-agent"
}

variable "query_dispatch_interval_cron" {
  type = string
  default = "rate(5 minutes)"
}

variable "lariat_payload_source" {
  type = string
}

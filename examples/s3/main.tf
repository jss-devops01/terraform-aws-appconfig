provider "aws" {
  region = local.region
}

locals {
  region = "us-east-1"
  name   = "example-${replace(basename(path.cwd), "_", "-")}"

  tags = {
    Example     = local.name
    Environment = "dev"
  }
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

################################################################################
# Supporting Resources
################################################################################

data "archive_file" "lambda_handler" {
  type        = "zip"
  source_file = "../_configs/validate.py"
  output_path = "../_configs/validate.zip"
}

module "validate_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 2"

  function_name = local.name
  description   = "Configuration semantic validation lambda"
  handler       = "validate.handler"
  runtime       = "python3.9"
  publish       = true
  memory_size   = 512
  timeout       = 120

  cloudwatch_logs_retention_in_days = 7
  attach_tracing_policy             = true
  tracing_mode                      = "Active"

  create_package         = false
  local_existing_package = data.archive_file.lambda_handler.output_path

  allowed_triggers = {
    AppConfig = {
      service = "appconfig"
    },
  }

  tags = local.tags
}

module "s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 2"

  bucket = "${local.name}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
  acl    = "private"

  attach_deny_insecure_transport_policy = true

  # Intended for example use only
  force_destroy = true

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  versioning = {
    enabled = true
  }

  tags = local.tags
}

resource "aws_s3_bucket_object" "config" {
  bucket                 = module.s3_bucket.s3_bucket_id
  key                    = "s3/config.json"
  source                 = "../_configs/config.json"
  etag                   = filemd5("../_configs/config.json")
  server_side_encryption = "AES256"

  tags = local.tags
}

################################################################################
# AppConfig
################################################################################

module "appconfig" {
  source = "../../"

  name        = local.name
  description = "S3 - ${local.name}"

  # environments
  environments = {
    nonprod = {
      name        = "nonprod"
      description = "NonProd environment - ${local.name}"
    },
    prod = {
      name        = "prod"
      description = "Prod environment - ${local.name}"
    }
  }

  # configuration profile
  use_s3_configuration        = true
  s3_configuration_bucket_arn = module.s3_bucket.s3_bucket_arn
  retrieval_role_description  = "Role to retrieve configuration stored in S3"
  config_profile_location_uri = "s3://${module.s3_bucket.s3_bucket_id}/${aws_s3_bucket_object.config.id}"
  config_profile_validator = [{
    type    = "JSON_SCHEMA"
    content = file("../_configs/config_validator.json")
    }, {
    type    = "LAMBDA"
    content = module.validate_lambda.lambda_function_arn
  }]

  # deployment
  deployment_configuration_version = aws_s3_bucket_object.config.version_id

  tags = local.tags
}

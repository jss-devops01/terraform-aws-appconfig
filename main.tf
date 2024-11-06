locals {
  retrieval_role_arn         = var.create_retrieval_role ? try(aws_iam_role.retrieval[0].arn, null) : var.config_profile_retrieval_role_arn
  retrieval_role_name        = var.retrieval_role_use_name_prefix ? null : coalesce(var.retrieval_role_name, var.name)
  retrieval_role_name_prefix = var.retrieval_role_use_name_prefix ? "${coalesce(var.retrieval_role_name, var.name)}-" : null
  is_windows                 = substr(pathexpand("~"), 0, 1) == "/" ? false : true
}

resource "aws_appconfig_application" "this" {
  count = var.create ? 1 : 0

  name        = var.name
  description = var.description

  # Hack to ensure permissions are available before config is retrieved by deployment
  depends_on = [
    aws_iam_role_policy_attachment.retrieval,
  ]

  # Hack to ensure permissions are available before config is retrieved by deployment
  provisioner "local-exec" {
    command     = "sleep 10"
    interpreter = local.is_windows ? ["PowerShell", "-Command"] : []
  }

  tags = var.tags
}

resource "aws_appconfig_environment" "this" {
  for_each = { for k, v in var.environments : k => v if var.create }

  name           = lookup(each.value, "name", var.name)
  description    = lookup(each.value, "description", var.description)
  application_id = aws_appconfig_application.this[0].id

  dynamic "monitor" {
    for_each = lookup(each.value, "monitor", {})
    content {
      alarm_arn      = monitor.value.alarm_arn
      alarm_role_arn = lookup(monitor.value, "alarm_role_arn", null)
    }
  }

  tags = merge(var.tags, lookup(each.value, "tags", {}))
}

resource "aws_appconfig_configuration_profile" "this" {
  for_each = var.create ? { for idx, cp in var.config_profiles : idx => cp } : {}

  application_id = aws_appconfig_application.this[0].id

  name        = each.value.name
  description = coalesce(each.value.description, var.description)
  type        = each.value.type

  location_uri       = each.value.location_uri
  retrieval_role_arn = var.use_hosted_configuration ? null : each.value.retrieval_role_arn

  dynamic "validator" {
    for_each = lookup(each.value, "validator", [])
    content {
      content = lookup(validator.value, "content", null)
      type    = lookup(validator.value, "type", null)
    }
  }

  tags = merge(var.tags, lookup(each.value, "tags", {}))
}

resource "aws_appconfig_hosted_configuration_version" "this" {
  for_each = var.create && var.use_hosted_configuration ? { for idx, acp in aws_appconfig_configuration_profile.this : idx => acp } : {}

  application_id           = aws_appconfig_application.this[0].id
  configuration_profile_id = split(":", each.value.id)[0]

  description  = lookup(var.hosted_config_version_description, each.key, coalesce(var.description, ""))
  content      = lookup(var.config_profiles, each.key).content
  content_type = var.config_profiles[each.key].content_type
}

resource "aws_appconfig_deployment_strategy" "this" {
  count = var.create && var.create_deployment_strategy ? 1 : 0

  name        = coalesce(var.deployment_strategy_name, var.name)
  description = coalesce(var.deployment_strategy_description, var.description)

  deployment_duration_in_minutes = var.deployment_strategy_deployment_duration_in_minutes
  final_bake_time_in_minutes     = var.deployment_strategy_final_bake_time_in_minutes
  growth_factor                  = var.deployment_strategy_growth_factor
  growth_type                    = var.deployment_strategy_growth_type
  replicate_to                   = var.deployment_strategy_replicate_to

  tags = merge(var.tags, var.deployment_strategy_tags)
}
resource "aws_appconfig_deployment" "this" {
  for_each = var.create  ? var.deployments_configuration : {}
    description              = coalesce(each.value.description, var.description)
    application_id           = aws_appconfig_configuration_profile.this[each.value.configuration_profile_name].application_id
    configuration_profile_id = aws_appconfig_configuration_profile.this[each.value.configuration_profile_name].configuration_profile_id
    configuration_version    = var.use_hosted_configuration ? aws_appconfig_hosted_configuration_version.this[each.value.configuration_profile_name].version_number : each.value.configuration_version
    deployment_strategy_id   = var.create_deployment_strategy ? aws_appconfig_deployment_strategy.this[0].id : var.deployment_strategy_id
    environment_id           = aws_appconfig_environment.this[each.value.environment_name].environment_id
    tags = merge(var.tags, each.value.tags)
}


################################################################################
# Configuration retrieval role
################################################################################

data "aws_iam_policy_document" "retrieval_ssm_parameter" {
  count = var.create && var.create_retrieval_role && var.use_ssm_parameter_configuration ? 1 : 0

  statement {
    sid       = "SsmParameterConfig"
    actions   = ["ssm:GetParameter"]
    resources = [var.ssm_parameter_configuration_arn]
  }
}

data "aws_iam_policy_document" "retrieval_ssm_document" {
  count = var.create && var.create_retrieval_role && var.use_ssm_document_configuration ? 1 : 0

  statement {
    sid       = "SsmDocumentConfig"
    actions   = ["ssm:GetDocument"]
    resources = [var.ssm_document_configuration_arn]
  }
}

data "aws_iam_policy_document" "retrieval_s3" {
  count = var.create && var.create_retrieval_role && var.use_s3_configuration ? 1 : 0

  statement {
    sid = "S3ConfigRead"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${var.s3_configuration_bucket_arn}/${var.s3_configuration_object_key}"]
  }

  statement {
    sid = "S3ConfigList"
    actions = [
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:ListBucketVersions",
      "s3:ListBucket",
    ]
    resources = [
      var.s3_configuration_bucket_arn,
      "${var.s3_configuration_bucket_arn}/*"
    ]
  }

  statement {
    sid = "S3ConfigListBucket"
    actions = [
      "s3:ListAllMyBuckets",
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "retreival" {
  source_policy_documents = compact([
    try(data.aws_iam_policy_document.retrieval_ssm_parameter[0].json, ""),
    try(data.aws_iam_policy_document.retrieval_ssm_document[0].json, ""),
    try(data.aws_iam_policy_document.retrieval_s3[0].json, ""),
  ])
}

resource "aws_iam_policy" "retrieval" {
  count = var.create && var.create_retrieval_role && !var.use_hosted_configuration ? 1 : 0

  name        = local.retrieval_role_name
  name_prefix = local.retrieval_role_name_prefix
  description = var.retrieval_role_description
  path        = var.retrieval_role_path
  policy      = data.aws_iam_policy_document.retreival.json

  tags = merge(var.tags, var.retrieval_role_tags)
}

resource "aws_iam_role_policy_attachment" "retrieval" {
  count = var.create && var.create_retrieval_role && !var.use_hosted_configuration ? 1 : 0

  role       = aws_iam_role.retrieval[0].name
  policy_arn = aws_iam_policy.retrieval[0].arn
}

resource "aws_iam_role" "retrieval" {
  count = var.create && var.create_retrieval_role && !var.use_hosted_configuration ? 1 : 0

  name                 = local.retrieval_role_name
  name_prefix          = local.retrieval_role_name_prefix
  description          = var.retrieval_role_description
  path                 = var.retrieval_role_path
  permissions_boundary = var.retrieval_role_permissions_boundary

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AppConfigAssume",
        Effect = "Allow",
        Action = "sts:AssumeRole",
        Principal = {
          Service = "appconfig.amazonaws.com"
        }
      }
    ]
  })

  # give IAM time to propagate or else assume role fails
  provisioner "local-exec" {
    command = "sleep 5"
    # Ensure windows always uses PowerShell, linux/mac use their default shell.
    interpreter = local.is_windows ? ["PowerShell", "-Command"] : []
  }

  tags = merge(var.tags, var.retrieval_role_tags)
}

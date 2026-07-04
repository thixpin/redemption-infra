resource "aws_ecr_repository" "app" {
  name                 = "${var.project}/redemption-api"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Cross-account image promotion: the BUILD (dev) account replicates every pushed
# image to the prod account's ECR, so prod pulls from its own registry and CI
# never needs prod credentials. Enable per account via variables:
#   dev/build account: ecr_replication_destination_account_ids = ["<prod>"]
#   prod account:      ecr_replication_source_account_id       = "<dev>"
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

resource "aws_ecr_replication_configuration" "this" {
  count = length(var.ecr_replication_destination_account_ids) > 0 ? 1 : 0

  replication_configuration {
    rule {
      dynamic "destination" {
        for_each = var.ecr_replication_destination_account_ids
        content {
          region      = var.region
          registry_id = destination.value
        }
      }
      repository_filter {
        filter      = "${var.project}/"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

resource "aws_ecr_registry_policy" "allow_replication" {
  count = var.ecr_replication_source_account_id != "" ? 1 : 0

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCrossAccountReplication"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.ecr_replication_source_account_id}:root" }
      Action    = ["ecr:CreateRepository", "ecr:ReplicateImage", "ecr:BatchImportUpstreamImage"]
      Resource  = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.project}/*"
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = { type = "expire" }
      },
      {
        # Immutable SHA tags accumulate forever; keep a bounded recent history.
        rulePriority = 10
        description  = "Keep only the 100 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 100
        }
        action = { type = "expire" }
      }
    ]
  })
}

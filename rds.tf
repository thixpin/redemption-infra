resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name}/db/credentials"
  kms_key_id              = aws_kms_key.rds.arn
  recovery_window_in_days = 7
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    dbname   = var.db_name
    port     = 5432
    host = module.rds_proxy.proxy_endpoint
  })
}

resource "aws_kms_key" "rds" {
  description             = "${local.name} Aurora + secrets encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = local.tags
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${local.name}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

# ---------------------------------------------------------------------------
# Security groups: 
#   - Aurora accepts 5432 only from the RDS Proxy SG.
#   - RDS Proxy accepts 5432 only from the EKS node SG.
# ---------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name_prefix = "${local.name}-aurora-"
  description = "Aurora PostgreSQL - ingress from RDS Proxy only"
  vpc_id      = module.vpc.vpc_id
  tags        = local.tags
}

resource "aws_security_group" "rds_proxy" {
  name_prefix = "${local.name}-rdsproxy-"
  description = "RDS Proxy - ingress from EKS nodes only"
  vpc_id      = module.vpc.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_proxy" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.rds_proxy.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "proxy_from_nodes" {
  security_group_id            = aws_security_group.rds_proxy.id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "proxy_to_rds" {
  security_group_id            = aws_security_group.rds_proxy.id
  referenced_security_group_id = aws_security_group.rds.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}


module "aurora" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 9.10"

  name              = "${local.name}-pg"
  engine            = "aurora-postgresql"
  engine_mode       = "provisioned"               # required for Serverless v2
  engine_version    = var.aurora_engine_version
  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn

  master_username             = var.db_username
  master_password             = random_password.db.result
  manage_master_user_password = false
  database_name               = var.db_name
  port                        = 5432

  serverlessv2_scaling_configuration = {
    min_capacity = var.aurora_min_acu
    max_capacity = var.aurora_max_acu
  }

  instance_class = "db.serverless"
  instances = {
    writer = {}
    reader = {}
  }

  vpc_id                 = module.vpc.vpc_id
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  create_db_subnet_group = false
  create_security_group  = false
  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period = 14
  deletion_protection     = true
  final_snapshot_identifier= "${local.name}-final-snapshot"
  skip_final_snapshot     = false

  performance_insights_enabled    = true
  monitoring_interval             = 60
  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = local.tags
}

# ---------------------------------------------------------------------------
# RDS Proxy - pools/multiplexes connections so 10x pods != 10x DB connections,
# ---------------------------------------------------------------------------
module "rds_proxy" {
  source  = "terraform-aws-modules/rds-proxy/aws"
  version = "~> 3.1"

  name                   = "${local.name}-proxy"
  vpc_subnet_ids         = module.vpc.database_subnets
  vpc_security_group_ids = [aws_security_group.rds_proxy.id]

  engine_family = "POSTGRESQL"
  debug_logging = false
  require_tls   = true

  auth = {
    (var.db_username) = {
      description = "Redemption DB credentials"
      auth_scheme = "SECRETS"
      secret_arn  = aws_secretsmanager_secret.db.arn
      iam_auth    = "REQUIRED"
    }
  }

  # Allow the proxy's IAM role to decrypt the secret with our KMS key.
  kms_key_arns = [aws_kms_key.rds.arn]

  # Register the Aurora cluster as the proxy target.
  target_db_cluster     = true
  db_cluster_identifier = module.aurora.cluster_id

  tags = local.tags
}

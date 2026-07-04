# Cluster add-ons required for the design to function:
#   - AWS Load Balancer Controller -> provisions the ALB for the Ingress
#   - metrics-server               -> feeds CPU/memory metrics to the HPA
#   - External Secrets Operator    -> syncs the DB secret from Secrets Manager
#   - kube-prometheus-stack        -> metrics, dashboards, alerting (observability)
module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.16"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # kube-prometheus-stack PVCs need the gp3 class (and thus the EBS CSI driver).
  depends_on = [kubernetes_storage_class_v1.gp3]

  enable_aws_load_balancer_controller = true
  enable_metrics_server               = true
  enable_external_secrets             = true

  helm_releases = {
    kube-prometheus-stack = {
      chart            = "kube-prometheus-stack"
      chart_version    = "62.3.0"
      repository       = "https://prometheus-community.github.io/helm-charts"
      namespace        = "monitoring"
      create_namespace = true
      values = [yamlencode({
        prometheus = {
          prometheusSpec = {
            retention = "15d"
            storageSpec = {
              volumeClaimTemplate = {
                spec = {
                  storageClassName = "gp3"
                  accessModes      = ["ReadWriteOnce"]
                  resources        = { requests = { storage = "20Gi" } }
                }
              }
            }
          }
        }
        alertmanager = {
          alertmanagerSpec = {
            # Default (OnNamespace) would only match alerts whose namespace ==
            # monitoring; our redemption alerts live in the redemption namespace,
            # so route by matchers only. See k8s/observability/alertmanagerconfig.yaml.
            alertmanagerConfigMatcherStrategy = { type = "None" }
            storage = {
              volumeClaimTemplate = {
                spec = {
                  storageClassName = "gp3"
                  accessModes      = ["ReadWriteOnce"]
                  resources        = { requests = { storage = "5Gi" } }
                }
              }
            }
          }
        }
        grafana = {
          persistence = {
            enabled          = true
            storageClassName = "gp3"
            accessModes      = ["ReadWriteOnce"]
            size             = "5Gi"
          }
          # Public URL Grafana serves behind. Needed so login/OAuth redirects use
          # https when the ALB terminates TLS (see k8s/observability/grafana-ingress.yaml).
          env = {
            GF_SERVER_ROOT_URL = "https://redemption-grafana-dev.thixpin.me"
          }
        }
      })]
    }
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# IRSA role: lets the External Secrets ServiceAccount in the app namespace read
# the DB credentials secret (and decrypt it). Least privilege - this one secret.
# ---------------------------------------------------------------------------
module "app_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${local.name}-external-secrets"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["redemption:redemption-secretstore"]
    }
  }
}

resource "aws_iam_policy" "read_db_secret" {
  name        = "${local.name}-read-db-secret"
  description = "Read the redemption DB credentials secret"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [aws_secretsmanager_secret.db.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.rds.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "app_secrets" {
  role       = module.app_secrets_irsa.iam_role_name
  policy_arn = aws_iam_policy.read_db_secret.arn
}

output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  description = "Command to configure kubectl against the cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "rds_proxy_endpoint" {
  description = "Connect the app here (not directly to RDS)"
  value       = module.rds_proxy.proxy_endpoint
}

output "aurora_writer_endpoint" {
  description = "Aurora cluster writer endpoint (app connects via the RDS Proxy, not this)"
  value       = module.aurora.cluster_endpoint
  sensitive   = true
}

output "aurora_reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = module.aurora.cluster_reader_endpoint
  sensitive   = true
}

output "db_secret_arn" {
  description = "Secrets Manager ARN consumed by External Secrets"
  value       = aws_secretsmanager_secret.db.arn
}

output "app_secrets_irsa_role_arn" {
  description = "Annotate the redemption-secretstore ServiceAccount with this"
  value       = module.app_secrets_irsa.iam_role_arn
}

# ALB hostnames — the app ALB is public, the shared admin ALB hosts Grafana + Argo CD.
data "aws_lbs" "app" {
  tags = {
    "elbv2.k8s.aws/cluster" = module.eks.cluster_name
    "ingress.k8s.aws/stack" = "redemption/redemption-api"
  }
}

data "aws_lb" "app" {
  for_each = data.aws_lbs.app.arns
  arn      = each.value
}

data "aws_lbs" "admin" {
  tags = {
    "elbv2.k8s.aws/cluster" = module.eks.cluster_name
    "ingress.k8s.aws/stack" = "redemption-admin" # shared Grafana + Argo CD IngressGroup
  }
}

data "aws_lb" "admin" {
  for_each = data.aws_lbs.admin.arns
  arn      = each.value
}

output "app_alb_hostname" {
  description = "Public app ALB — CNAME redemption-dev here"
  value       = try(one([for lb in data.aws_lb.app : lb.dns_name]), "(not provisioned yet — sync the app Ingress first)")
}

output "admin_alb_hostname" {
  description = "Shared admin ALB (Grafana + Argo CD) — CNAME redemption-grafana-dev AND redemption-argocd-dev here"
  value       = try(one([for lb in data.aws_lb.admin : lb.dns_name]), "(not provisioned yet — apply the Grafana/Argo CD Ingresses first)")
}

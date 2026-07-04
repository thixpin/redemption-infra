# PROD environment (separate AWS account). Apply with prod credentials:
#   terraform init -reconfigure -backend-config=envs/prod/backend.hcl
#   terraform apply -var-file=envs/prod/terraform.tfvars
region          = "ap-southeast-1"
project         = "redemption"
environment     = "prod"
cluster_version = "1.35"

vpc_cidr = "10.0.0.0/16" # separate account, never peered with dev; if you plan
# peering, change this AND the CIDRs in k8s/app/base/networkpolicy.yaml (prod overlay patch)
az_count = 3

# Prod capacity: higher floor (no cold start on first spike) and more headroom.
aurora_engine_version = "16.4"
aurora_min_acu        = 0.5
aurora_max_acu        = 64

# Prod-account admin role(s) that get cluster-admin
cluster_admin_role_arns = [
  # "arn:aws:iam::<PROD_ACCOUNT_ID>:role/<your-prod-admin-role>"
]

# Lock the EKS API endpoint in prod (office/VPN CIDRs)
# cluster_endpoint_public_access_cidrs = ["x.x.x.x/32"]

grafana_hostname = "redemption-grafana.thixpin.me"

# Allow the dev/build account to replicate images into this account's ECR.
ecr_replication_source_account_id = "801100257021"

# Alertmanager notification secrets — set via TF_VAR_* env vars, not here.

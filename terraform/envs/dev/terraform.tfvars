# Copy to terraform.tfvars and adjust. Do NOT commit real values.
region          = "ap-southeast-1"
project         = "redemption"
environment     = "dev"
cluster_version = "1.35"

vpc_cidr = "10.0.0.0/16"
az_count = 3

# Aurora PostgreSQL Serverless v2 capacity range (ACUs; 1 ACU ~= 2 GiB RAM)
aurora_engine_version = "16.4"
aurora_min_acu        = 0.5
aurora_max_acu        = 32

# IAM roles that should get cluster-admin (e.g. your SSO admin role ARN)
cluster_admin_role_arns = [
  # "arn:aws:iam::111122223333:role/AWSReservedSSO_AdministratorAccess_xxxx"
  "arn:aws:iam::801100257021:role/aws-reserved/sso.amazonaws.com/ap-southeast-1/AWSReservedSSO_AWSAdministratorAccess_4780bb43dbba39ed"
]

# Alertmanager notification secrets (kept out of git via this file).
# slack_webhook_url     = "https://hooks.slack.com/services/T000/B000/XXXXXXXX"
# pagerduty_routing_key = "your-pagerduty-events-v2-routing-key"

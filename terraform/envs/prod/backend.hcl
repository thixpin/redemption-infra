# S3 remote-state backend for the PROD account (separate AWS account).
# Create the bucket + lock table in the prod account first (SETUP.md §1), then:
#   terraform init -reconfigure -backend-config=envs/prod/backend.hcl
bucket         = "redemption-prod-terraform-state-770385967466"
key            = "redemption/infra.tfstate"
region         = "ap-southeast-1"
dynamodb_table = "redemption-prod-terraform-locks"
encrypt        = true

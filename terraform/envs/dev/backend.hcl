# S3 remote-state backend configuration (partial config).
# Applied at init time:  terraform init -backend-config=backend.hcl
bucket         = "redemption-dev-terraform-state-801100257021" # <- replace with your bucket
key            = "redemption/infra.tfstate"
region         = "ap-southeast-1"                       # <- replace with your region
dynamodb_table = "redemption-dev-terraform-locks"              # <- replace with your dynamodb_table
encrypt        = true

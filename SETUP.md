

## Create a new s3 bucket and dynamodb table for terraform backend

```bash
export PROJECT="redemption"
export ENVIRONMENT="dev"
export AWS_REGION="ap-southeast-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export TF_BACKEND_BUCKET="${PROJECT}-${ENVIRONMENT}-terraform-state-${AWS_ACCOUNT_ID}"
export TF_BACKEND_TABLE="${PROJECT}-${ENVIRONMENT}-terraform-locks"
aws s3 mb s3://${TF_BACKEND_BUCKET} --region ${AWS_REGION}
# redemption-dev-terraform-state-801100257021
aws s3api put-bucket-versioning --bucket ${TF_BACKEND_BUCKET} --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket ${TF_BACKEND_BUCKET} --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
aws dynamodb create-table \
    --table-name ${TF_BACKEND_TABLE} \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST --region ${AWS_REGION}
# redemption-dev-terraform-locks

terraform init  -backend-config=backend.hcl
terraform validate
terraform plan 

```

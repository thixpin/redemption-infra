

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
terraform apply 
```

# Configure GitHub Actions OIDC provider in AWS IAM

```bash 
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 

# Create a trust policy document for the GitHub Actions OIDC provider
cat <<EOT > github-actions-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {   
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:thixpin/redemption-app:ref:refs/heads/main"
        }
      }
    }
  ]
}
EOT

# Create AIM Role to allow GitHub Actions to assume the role and deploy to AWS
aws iam create-role \
  --role-name ${PROJECT}-${ENVIRONMENT}-github-actions \
  --assume-role-policy-document file://github-actions-trust-policy.json

# Create a policy for the role to allow it to deploy resources
cat <<EOT > github-actions-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "*"
    }
  ]
}
EOT

aws iam put-role-policy \
  --role-name ${PROJECT}-${ENVIRONMENT}-github-actions \
  --policy-name ${PROJECT}-${ENVIRONMENT}-github-actions-policy \
  --policy-document file://github-actions-policy.json
```

## Add the repo secret** in the app repo:

```
Settings → Secrets and variables → Actions → New secret
Name:  AWS_CI_ROLE_ARN
Value: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-github-ci
```

##  Connect kubectl and sanity-check the cluster

```bash
$(terraform output -raw configure_kubectl)
kubectl get nodes
kubectl get pods -A    

kubectl apply -f k8s/karpenter/


kubectl create namespace argocd
kubectl create namespace redemption
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/application-app-dev.yaml
kubectl apply -f argocd/application-karpenter.yaml
kubectl apply -f argocd/application-observability.yaml
kubectl -n argocd get applications
kubectl -n redemption get pods

```
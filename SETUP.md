# Redemption — Infrastructure Setup

End-to-end bootstrap for the Redemption platform on AWS EKS. Run the steps in
order; each assumes the previous one succeeded.

## Overview

Two repositories:

| Repo | Contents |
|------|----------|
| **`redemption-infra`** (this repo) | Terraform (VPC, EKS, Aurora, Karpenter, add-ons) + Kubernetes manifests + Argo CD Applications. **Source of truth for GitOps.** |
| **`redemption-app`** | Application source, Dockerfile, and CI (build → scan → push image → bump the dev overlay here). |

Delivery model: **Terraform** provisions AWS + cluster add-ons; **Argo CD** deploys
all workloads from `redemption-infra`; **CI** ships immutable git-SHA images and
bumps the image tag, which Argo CD syncs.

## Prerequisites

- `awscli` v2 (authenticated with admin for bootstrap), `terraform` >= 1.5, `kubectl`, `helm`, `git`.
- A GitHub org/user owning both repos, and this repo pushed to `origin/main`.
- An ACM certificate covering the app/dashboard hostnames (a `*.thixpin.me` wildcard) in the cluster region.
- DNS for the domain (Cloudflare in this setup).

```bash
export PROJECT="redemption"
export ENVIRONMENT="dev"
export AWS_REGION="ap-southeast-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER_NAME="${PROJECT}-${ENVIRONMENT}"        # redemption-dev
```

## 1. Configure `terraform.tfvars`

Set at least these in `terraform/terraform.tfvars` before applying:

```hcl
# terraform/terraform.tfvars
cluster_admin_role_arns = ["arn:aws:iam::<acct>:role/<your-admin-or-SSO-role>"]  # gets cluster-admin
# Optional hardening / integrations:
# cluster_endpoint_public_access_cidrs = ["<your.ip>/32"]   # lock the API endpoint (default 0.0.0.0/0)
# slack_webhook_url     = "https://hooks.slack.com/services/..."   # Alertmanager
# pagerduty_routing_key = "..."                                     # Alertmanager (critical)
```

> Keep secrets out of git — pass `slack_webhook_url` etc. via `TF_VAR_...` env vars
> or a git-ignored `*.auto.tfvars` rather than committing them.

## 2. Terraform state backend (S3 + DynamoDB)

Create once per account/environment:

```bash
export TF_BACKEND_BUCKET="${PROJECT}-${ENVIRONMENT}-terraform-state-${AWS_ACCOUNT_ID}"
export TF_BACKEND_TABLE="${PROJECT}-${ENVIRONMENT}-terraform-locks"

aws s3 mb "s3://${TF_BACKEND_BUCKET}" --region "${AWS_REGION}"
aws s3api put-bucket-versioning --bucket "${TF_BACKEND_BUCKET}" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "${TF_BACKEND_BUCKET}" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
aws dynamodb create-table --table-name "${TF_BACKEND_TABLE}" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region "${AWS_REGION}"
```

Ensure `terraform/backend.hcl` matches those names (bucket / dynamodb_table / region).

## 3. Provision infrastructure

All Terraform lives in `terraform/` — run these from there:

```bash
cd terraform
terraform init -backend-config=backend.hcl
terraform validate
terraform plan
terraform apply
```

This creates the VPC (3 tiers × 3 AZs), EKS, Aurora Serverless v2 + RDS Proxy,
ECR, Karpenter (controller), and add-ons (AWS LB Controller, metrics-server,
External Secrets, kube-prometheus-stack, EBS CSI, prometheus-adapter).

Useful outputs:

```bash
terraform output configure_kubectl
terraform output ecr_repository_url
terraform output rds_proxy_endpoint
```

## 4. GitHub Actions OIDC + CI role (for the app repo)

Lets `redemption-app` CI push to ECR without static keys. Trust is scoped to the
`main` branch of the app repo (see `github-actions-trust-policy.json`).

```bash
cd ..   # back to the repo root — the JSON policy docs live here

# OIDC provider (skip if it already exists in the account)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# Role + policy (JSON docs are in this repo)
aws iam create-role --role-name "${CLUSTER_NAME}-github-actions" \
  --assume-role-policy-document file://github-actions-trust-policy.json
aws iam put-role-policy --role-name "${CLUSTER_NAME}-github-actions" \
  --policy-name "${CLUSTER_NAME}-github-actions-policy" \
  --policy-document file://github-actions-policy.json
```

> Edit the account ID / repo / branch in `github-actions-trust-policy.json` to match yours.

## 5. GitHub repo secrets (in `redemption-app`)

`Settings → Secrets and variables → Actions`:

| Secret | Value |
|--------|-------|
| `AWS_CI_ROLE_ARN` | `arn:aws:iam::<acct>:role/redemption-dev-github-actions` (from step 4) |
| `INFRA_REPO_TOKEN` | Fine-grained PAT / GitHub App token with **Contents: read/write** on `redemption-infra` (CI bumps the image tag there) |

## 6. Configure kubectl access

```bash
$(terraform -chdir=terraform output -raw configure_kubectl)   # aws eks update-kubeconfig ...
kubectl get nodes
```

> **Access is not automatic.** Only the cluster **creator** and the roles listed
> in `cluster_admin_role_arns` get cluster-admin (via EKS access entries). If
> `kubectl` returns `Unauthorized`, you're using a different identity — either
> assume an admin role that's in that list, or grant your principal an access entry:
>
> ```bash
> aws eks create-access-entry --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
>   --principal-arn <your-principal-arn>
> aws eks associate-access-policy --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
>   --principal-arn <your-principal-arn> \
>   --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
>   --access-scope type=cluster
> ```

## 7. Bootstrap Argo CD (GitOps)

```bash
kubectl create namespace argocd
kubectl create namespace redemption
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server

# If redemption-infra is PRIVATE, register repo creds so Argo can pull it:
#   argocd repo add https://github.com/<org>/redemption-infra.git --username <u> --password <token>
# (or create an argocd repo Secret). Public repos need nothing.

# Apply the Argo CD project + Applications (they point at redemption-infra/main)
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/application-app-dev.yaml
kubectl apply -f argocd/application-karpenter.yaml
kubectl apply -f argocd/application-observability.yaml

# Argo CD UI ingress (joins the shared "redemption-admin" ALB with Grafana)
kubectl apply -f argocd/ingress.yaml

kubectl -n argocd get applications
```

Argo CD now reconciles: Karpenter NodePool/EC2NodeClass, the app (namespace
`redemption`), and observability CRs (namespace `monitoring`).

## 8. First application deploy

The dev overlay's image tag is a placeholder until CI publishes one:

```bash
# In the redemption-app repo:
git push origin main
```

CI: tests → **multi-arch build (arm64 + amd64)** → Trivy scan → push
`:<sha>` to ECR → bump `k8s/app/overlays/dev/kustomization.yaml` in this repo →
Argo CD syncs → pods roll out.

```bash
kubectl -n redemption get pods -w
```

## 9. DNS (Cloudflare, manual)

Two ALBs: the **app ALB** (public) and the **shared admin ALB** — Grafana and
Argo CD join the same `redemption-admin` IngressGroup, so both admin hosts CNAME
to the **same** ALB hostname. Get the hostnames (either way):

```bash
terraform -chdir=terraform output app_alb_hostname     # app ALB
terraform -chdir=terraform output admin_alb_hostname   # shared admin ALB
# or from the cluster:
kubectl -n redemption get ingress redemption-api \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'   # app ALB
kubectl -n monitoring get ingress grafana \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'   # shared admin ALB
```

Create **DNS-only (grey-cloud) CNAMEs**:

| Type | Name | Target | Proxy |
|------|------|--------|-------|
| CNAME | `redemption-dev` | `<app ALB hostname>` | DNS only |
| CNAME | `redemption-grafana-dev` | `<shared admin ALB hostname>` | DNS only |
| CNAME | `redemption-argocd-dev` | `<same shared admin ALB hostname>` | DNS only |

DNS-only keeps the ALB (ACM TLS + WAF) as the edge. The wildcard `*.thixpin.me`
ACM cert covers all hosts.

Verify: `curl https://redemption-dev.thixpin.me/health` → `{"status":"ok"}`.

## 10. Admin UIs (Grafana / Argo CD)

Both are served from the **shared, CIDR-gated admin ALB**:
`https://redemption-grafana-dev.thixpin.me` and
`https://redemption-argocd-dev.thixpin.me`. The `inbound-cidrs` annotation
(identical on both ingresses — it configures the one shared ALB) must include
your office/VPN CIDR.

Credentials:

```bash
# Grafana (user: admin) — change the default password after first login
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo

# Argo CD (user: admin) — then delete this bootstrap secret
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
# CLI through the ALB:  argocd login redemption-argocd-dev.thixpin.me --grpc-web
```

Port-forward remains the zero-exposure fallback:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

## 11. Verify

```bash
kubectl -n redemption get pods,hpa,ingress
kubectl -n monitoring get pods,pvc                     # PVCs Bound on gp3
kubectl get apiservice v1beta1.custom.metrics.k8s.io   # Available: True (RPS HPA)
kubectl -n argocd get applications                     # all Synced / Healthy
curl -s https://redemption-dev.thixpin.me/api/codes
```

## Operations notes & gotchas

- **NetworkPolicy enforcement** is enabled on the VPC CNI. If you change
  `networkpolicy.yaml`, push it (Argo syncs) **before** anything that relies on
  it, and keep the ALB ingress rule (VPC CIDR on :3000) — the ip-target ALB
  connects from VPC ENIs, not from a pod.
- **ECR is immutable** — CI only ever pushes new git-SHA tags (no moving `:dev`).
- **Rollback** a bad deploy with `git revert` in this repo; Argo CD re-syncs the
  previous immutable tag.
- **Lock down** the EKS public endpoint (`cluster_endpoint_public_access_cidrs`)
  and the admin ALB `inbound-cidrs` for anything beyond a demo.
- **Shared admin ALB**: ALB-level annotations (scheme, `inbound-cidrs`, WAF,
  certs) must stay IDENTICAL on every ingress in the `redemption-admin` group —
  they configure the single shared ALB. Changing `group.name` replaces the ALB
  (new hostname → update the CNAMEs).

## Teardown

```bash
# Remove Argo CD Applications first so finalizers clean up ALBs/targets, then:
cd terraform && terraform destroy
```

> Aurora has `deletion_protection = true` and takes a final snapshot; disable/adjust
> in `terraform/rds.tf` if you need an unattended destroy.

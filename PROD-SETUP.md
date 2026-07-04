# Redemption — PROD Environment Setup

Bootstrap runbook for the **production** environment in its own AWS account
(`770385967466`), reusing this repo's root module and `overlays/prod` manifests.
Dev setup and shared background: [`SETUP.md`](./SETUP.md).

**Topology:** separate account + cluster (`redemption-prod`), its own VPC,
Aurora, ECR, and Argo CD instance. Nothing is shared with dev except the git
repos and the Cloudflare DNS zone.

**Release model:** prod deploys only on release tags — `v*` on `main` triggers
`deploy-prod.yaml` (test → multi-arch build of the tagged commit → Trivy scan →
push to **prod ECR** → bump `k8s/app/overlays/prod` → prod Argo CD syncs).

## 0. Prerequisites

- Prod-account admin credentials (e.g. `arn:aws:iam::770385967466:role/KubeAdminRole`).
- ACM **wildcard cert** for `*.thixpin.me` in `ap-southeast-1` **in the prod
  account** (already referenced in the overlays: `2d098864-...`).
- (Optional) a prod WAF web ACL — referenced in `k8s/app/overlays/prod/ingress-patch.yaml`.
- All `<PROD_*>` placeholders filled — verify none remain:

```bash
grep -rn "<PROD_" k8s argocd terraform/envs && echo "FILL THESE FIRST" || echo "ready"
```

```bash
export PROJECT="redemption"
export ENVIRONMENT="prod"
export AWS_REGION="ap-southeast-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)  # 770385967466
export CLUSTER_NAME="${PROJECT}-${ENVIRONMENT}"   # redemption-prod
```

## 1. Terraform state backend

Same as `SETUP.md §2`, in the prod account:

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

Must match `terraform/envs/prod/backend.hcl`.

## 2. Provision infrastructure

```bash
cd terraform
terraform init -reconfigure -backend-config=envs/prod/backend.hcl
terraform plan  -var-file=envs/prod/terraform.tfvars
terraform apply -var-file=envs/prod/terraform.tfvars
cd ..
```

Prod tfvars differences from dev: `environment = "prod"`, Aurora `1–64 ACU`
(higher floor — no cold start on the first spike), `grafana_hostname =
redemption-grafana.thixpin.me`. Consider setting
`cluster_endpoint_public_access_cidrs` to office/VPN ranges from day one.

> Switching back to dev later: `terraform init -reconfigure -backend-config=envs/dev/backend.hcl`.

## 3. CI role (GitHub OIDC) + repo secret

`deploy-prod.yaml` needs a role **in the prod account** to push images:

```bash
# OIDC provider (once per account)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# Role + ECR push policy (JSON docs at repo root; trust allows develop/main/v* tags —
# set the account ID inside github-actions-trust-policy.json to 770385967466 first)
aws iam create-role --role-name "${CLUSTER_NAME}-github-actions" \
  --assume-role-policy-document file://github-actions-trust-policy.json
aws iam put-role-policy --role-name "${CLUSTER_NAME}-github-actions" \
  --policy-name "${CLUSTER_NAME}-github-actions-policy" \
  --policy-document file://github-actions-policy.json
```

Then in the **`redemption-app`** repo → Settings → Secrets → Actions:

| Secret | Value |
|--------|-------|
| `AWS_CI_ROLE_ARN_PROD` | `arn:aws:iam::770385967466:role/redemption-prod-github-actions` |

## 4. kubectl access

```bash
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"
kubectl get nodes
```

Only the cluster creator and `cluster_admin_role_arns` (KubeAdminRole) have
access — grant others via EKS access entries (`SETUP.md §6`).

## 5. Bootstrap Argo CD (prod runs its own)

```bash
kubectl create namespace argocd
kubectl create namespace redemption
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server

# private repo? register creds (SETUP.md §7), then:
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/prod/                 # app-prod, karpenter, observability, UI ingress
kubectl apply -f argocd/argocd-cm-health.yaml # HPA health-check override
kubectl -n argocd rollout restart statefulset/argocd-application-controller
```

### ⚠️ First-sync bootstrap: DB secret before the migrate hook

The app sync runs the **PreSync migrate Job first**, but the Job needs the
`redemption-db` Secret, which the **ExternalSecret only creates during the main
sync** — a first-boot deadlock. Break it once by applying the secret-sync
resources ahead of Argo CD:

```bash
kubectl kustomize k8s/app/overlays/prod \
  | yq 'select(.kind == "ServiceAccount" or .kind == "SecretStore" or .kind == "ExternalSecret")' \
  | kubectl apply -f -
kubectl -n redemption get secret redemption-db   # wait until it exists
```

After that, every subsequent sync is self-sufficient (the Secret persists).

## 6. First release

```bash
# in redemption-app, after merging develop -> main:
git tag v1.0.0 && git push origin main --tags

# --- optional: create the `bootstrap` tag ------------------------------------
# Only needed if Argo CD synced BEFORE the first release (the overlay's
# placeholder tag `bootstrap` doesn't exist in ECR -> migrate Job
# ImagePullBackOff). Point `bootstrap` at the released image. Use imagetools
# (manifest copy) — a docker pull/tag/push would flatten the multi-arch image
# to a single arch and crash on the arm64/amd64 node mix.
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

RELEASED_SHA=$(git rev-parse --short=12 v1.0.0)
PROD_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/redemption/redemption-api"
docker buildx imagetools create -t "${PROD_REPO}:bootstrap" "${PROD_REPO}:${RELEASED_SHA}"
# ------------------------------------------------------------------------------
```

Watch: GitHub Actions `Deploy Prod` → image in prod ECR → commit
`deploy(prod): ...` in this repo → prod Argo CD sync:

```bash
kubectl -n redemption get pods -w
```

## 7. DNS (Cloudflare, DNS-only CNAMEs)

```bash
cd terraform
terraform apply -refresh-only -var-file=envs/prod/terraform.tfvars
cd ..
terraform -chdir=terraform output app_alb_hostname     # app ALB
terraform -chdir=terraform output admin_alb_hostname   # shared admin ALB (Grafana + Argo CD)
```

| Type | Name | Target |
|------|------|--------|
| CNAME | `redemption-api` | `<prod app ALB hostname>` |
| CNAME | `redemption-grafana` | `<prod admin ALB hostname>` |
| CNAME | `redemption-argocd` | `<same prod admin ALB hostname>` |

## 8. Admin UIs

- Grafana: `https://redemption-grafana.thixpin.me` — password:
  `kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d`
  (**change it**).
- Argo CD: `https://redemption-argocd.thixpin.me` — password:
  `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`
  (change it, then delete the bootstrap secret).
- Both sit behind the CIDR-allowlisted admin ALB (`inbound-cidrs` — identical on
  both ingresses; keep it tight in prod).

## 9. Verify

```bash
kubectl -n redemption get pods,hpa,ingress,pdb   # pods Ready, PDB allows 1 disruption
kubectl -n monitoring get pods,pvc               # monitoring up, PVCs Bound (gp3)
kubectl get apiservice v1beta1.custom.metrics.k8s.io          # Available: True
kubectl get ec2nodeclass,nodepool                # Ready: True (redemption-prod role/tags)
kubectl -n argocd get applications               # Synced / Healthy
curl -s https://redemption-api.thixpin.me/health # {"status":"ok"}
curl -s https://redemption-api.thixpin.me/api/codes
```

## Prod-specific gotchas

- **No demo data**: the app no longer seeds on boot; prod starts with empty
  tables (`npm run db:init` is dev-only). Load real codes via the API.
- **WAF blocks VPN/hosting IPs**: the ACL's `AnonymousIpList` managed rules
  reject cloud/VPN egress IPs — test from a residential/office network or add
  your IPs to the ACL's allow IP-set (this bit us in dev).
- **Rollback** = `git revert` the `deploy(prod): ...` commit in this repo (or
  re-tag an older commit); Argo CD re-syncs the previous immutable image.
- **Admin ALB group rules**: ALB-level annotations must stay identical on every
  `redemption-admin` ingress; changing `group.name` replaces the ALB → new
  hostname → update CNAMEs.
- **Migrations must stay backward-compatible** (expand → contract): the PreSync
  Job runs the new schema against the DB the old pods are still using.

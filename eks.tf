# EKS cluster. Private worker subnets; API endpoint reachable privately (and
# publicly only for bootstrapping — lock this down / restrict CIDRs in prod).
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = local.name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Secrets envelope-encrypted at rest with a dedicated KMS key.
  create_kms_key            = true
  cluster_encryption_config = { resources = ["secrets"] }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  enable_irsa = true

  # Control-plane logging for audit / observability.
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
    aws-ebs-csi-driver     = { most_recent = true }
  }

  # A small, always-on managed node group hosts cluster-critical add-ons
  # (CoreDNS, Karpenter controller, ALB controller). Application workloads run
  # on Karpenter-provisioned nodes (see karpenter.tf + k8s/karpenter).
  eks_managed_node_groups = {
    system = {
      instance_types = ["m6g.large"]
      ami_type       = "AL2023_ARM_64_STANDARD"
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      labels         = { role = "system" }
    }
  }

  # Nodes launched by Karpenter must be allowed to join the cluster.
  node_security_group_tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.name
  })

  # Grant listed IAM roles cluster-admin via EKS access entries (no aws-auth cm).
  enable_cluster_creator_admin_permissions = true
  access_entries = {
    for arn in var.cluster_admin_role_arns : arn => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  tags = local.tags
}

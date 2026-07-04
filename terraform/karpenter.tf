# Karpenter: node autoscaling that provisions controller. 
# The NodePool / EC2NodeClass custom resources live in k8s/karpenter.

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.24"

  cluster_name = module.eks.cluster_name

  # Pin a deterministic node role name so k8s/karpenter/ec2nodeclass.yaml can
  # reference it directly (module default adds a random suffix).
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${local.name}-karpenter-node"

  enable_irsa            = true
  irsa_oidc_provider_arn = module.eks.oidc_provider_arn
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"

  version = "1.3.3"
  wait    = true

  values = [<<-EOT
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: ${module.karpenter.iam_role_arn}
    controller:
      resources:
        requests:
          cpu: 500m
          memory: 512Mi
  EOT
  ]

  depends_on = [module.eks]
}

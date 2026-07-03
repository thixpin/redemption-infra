# ---------------------------------------------------------------------------
# EBS CSI driver + a gp3 StorageClass so PersistentVolumeClaims can bind.
# Required by kube-prometheus-stack (Prometheus / Alertmanager / Grafana all
# request PVCs); without this the monitoring pods sit Pending forever.
#
# Installed as a standalone aws_eks_addon (not in the eks module's cluster_addons)
# so the addon's IRSA role can depend on module.eks.oidc_provider_arn without
# creating a dependency cycle back into the module.
# ---------------------------------------------------------------------------
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name             = "${local.name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.ebs_csi_irsa.iam_role_arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags
}

# Encrypted gp3 class, referenced explicitly by the monitoring stack. Not marked
# default to avoid clashing with the EKS-provided gp2 default class.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}

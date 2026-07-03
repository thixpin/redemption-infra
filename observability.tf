# Notification credentials consumed by the GitOps-managed AlertmanagerConfig
# (k8s/observability/alertmanagerconfig.yaml). Kept out of git via tfvars.
# Only created when at least one channel is configured; if absent, Alertmanager
# simply skips the AlertmanagerConfig (no crash).
resource "kubernetes_secret" "alertmanager_notifications" {
  count = var.slack_webhook_url != "" || var.pagerduty_routing_key != "" ? 1 : 0

  metadata {
    name      = "alertmanager-notifications"
    namespace = "monitoring"
  }

  data = {
    "slack-webhook-url"     = var.slack_webhook_url
    "pagerduty-routing-key" = var.pagerduty_routing_key
  }

  # The monitoring namespace is created by the kube-prometheus-stack release.
  depends_on = [module.eks_blueprints_addons]
}

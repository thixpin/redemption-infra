# prometheus-adapter: serves the custom.metrics.k8s.io API 
resource "helm_release" "prometheus_adapter" {
  name       = "prometheus-adapter"
  namespace  = "monitoring"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-adapter"
  version    = "4.11.0"

  values = [yamlencode({
    prometheus = {
      # Prometheus Service created by kube-prometheus-stack (release name +
      # "-prometheus"). Adjust if your Helm release name differs.
      url  = "http://kube-prometheus-stack-prometheus.monitoring.svc"
      port = 9090
    }
    rules = {
      # Only expose our custom rule; skip the adapter's default rule set.
      default = false
      custom = [
        {
          # The app's request counter, restricted to series carrying pod/namespace
          # labels (added by the ServiceMonitor scrape).
          seriesQuery = "http_request_duration_seconds_count{namespace!=\"\",pod!=\"\"}"
          resources = {
            overrides = {
              namespace = { resource = "namespace" }
              pod       = { resource = "pod" }
            }
          }
          name = {
            matches = "^http_request_duration_seconds_count$"
            as      = "http_requests_per_second"
          }
          # Per-pod request rate over a 2m window -> Pods AverageValue target.
          metricsQuery = "sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)"
        }
      ]
    }
  })]

  # Needs the Prometheus service (from kube-prometheus-stack) to exist.
  depends_on = [module.eks_blueprints_addons]
}

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

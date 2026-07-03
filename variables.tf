variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project / name prefix"
  type        = string
  default     = "redemption"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones (>=3 for HA)"
  type        = number
  default     = 3
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.35"
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version (must support Serverless v2)"
  type        = string
  default     = "16.4"
}

variable "aurora_min_acu" {
  description = "Aurora Serverless v2 minimum capacity (ACUs; 1 ACU ~= 2 GiB RAM)"
  type        = number
  default     = 0.5
}

variable "aurora_max_acu" {
  description = "Aurora Serverless v2 maximum capacity (ACUs) - headroom for the 10x spike"
  type        = number
  default     = 32
}

variable "db_name" {
  description = "Application database name"
  type        = string
  default     = "redemption"
}

variable "db_username" {
  description = "Master DB username"
  type        = string
  default     = "redemption_admin"
}

variable "cluster_admin_role_arns" {
  description = "IAM role ARNs granted cluster-admin via EKS access entries"
  type        = list(string)
  default     = []
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS public API endpoint. Restrict to admin/office/VPN ranges in prod (private access stays on for in-cluster/VPC clients)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL for Alertmanager notifications (leave empty to skip)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "pagerduty_routing_key" {
  description = "PagerDuty Events v2 routing key for critical Alertmanager alerts (leave empty to skip)"
  type        = string
  default     = ""
  sensitive   = true
}

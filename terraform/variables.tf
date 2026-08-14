variable "region" {
  description = "Brewline runs in a single region so latency between services stays negligible."
  type        = string
  default     = "eu-central-1"
}

variable "project" {
  description = "Resource name prefix."
  type        = string
  default     = "brewline"
}

variable "incident_topic_name" {
  description = <<-EOT
    The shared SNS topic our alarms notify. Owned by the platform team and looked up rather than
    created here, so tearing down a Brewline environment never removes it.
  EOT
  type        = string
  default     = "OpsFabric-Incidents"
}

variable "deployment_profile" {
  description = <<-EOT
    Which tuning profile this environment runs with. Each one trades something off; `standard` is
    what production uses.

      standard              balanced defaults
      tight-latency-budget  hard 10s ceiling on checkout, to accommodate downstream payment
                            gateway latency (5+ seconds observed); provides 2x safety margin
      cost-capped           reserved concurrency on payment, to bound spend in lower environments
      fast-redelivery       short queue visibility, so stuck fulfilment retries sooner
      promo-pricing         enables promo-only orders (store credit, gift cards) in the order mix
      least-privilege       the tightened IAM posture the security review asked for
  EOT
  type        = string
  default     = "standard"

  validation {
    condition = contains([
      "standard", "tight-latency-budget", "cost-capped",
      "fast-redelivery", "promo-pricing", "least-privilege",
    ], var.deployment_profile)
    error_message = "Unknown profile. Pick one of: standard, tight-latency-budget, cost-capped, fast-redelivery, promo-pricing, least-privilege."
  }
}

variable "traffic_enabled" {
  description = "Whether the synthetic order generator runs. Off in production, on everywhere else."
  type        = bool
  default     = true
}

variable "traffic_rate" {
  description = "How often the synthetic generator places orders."
  type        = string
  default     = "rate(1 minute)"
}

variable "traffic_orders_per_run" {
  description = "Orders placed per generator run."
  type        = number
  default     = 5
}

variable "log_retention_days" {
  description = "Log retention. Short outside production — retention is what makes CloudWatch cost money."
  type        = number
  default     = 3
}

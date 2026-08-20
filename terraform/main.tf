terraform {
  # 1.10+ for `use_lockfile`, which does S3-native state locking and saves standing up a
  # DynamoDB table just for this.
  required_version = ">= 1.10"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }

  backend "s3" {
    bucket = "devops-project-terraform-remote-backend"
    key    = "brewline-manual-testing/terraform.tfstate"
    # The bucket's own region, which is NOT where the estate is deployed — the provider below
    # puts every resource in eu-central-1.
    region       = "ca-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Profile   = var.deployment_profile
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Owned by the platform team. Looked up rather than created, so `terraform destroy` on a Brewline
# environment can never take the shared alerting topic down with it.
data "aws_sns_topic" "incidents" {
  name = var.incident_topic_name
}

locals {
  name = var.project

  services = {
    checkout  = "${var.project}-checkout-api"
    payment   = "${var.project}-payment-gateway"
    worker    = "${var.project}-order-worker"
    inventory = "${var.project}-inventory-api"
    traffic   = "${var.project}-traffic-generator"
  }

  # Source directory per service. Spelled out rather than derived from the key, because the
  # directory names read as code (`order_worker`) and the AWS names read as estate
  # (`brewline-order-worker`); deriving one from the other only works until it doesn't.
  service_dirs = {
    checkout  = "checkout_api"
    payment   = "payment_gateway"
    worker    = "order_worker"
    inventory = "inventory_api"
    traffic   = "traffic_generator"
  }

  # ── Profile tuning ─────────────────────────────────────────────────────────────────────────
  # Each profile moves a small number of knobs. Anything the active profile does not name keeps
  # its standard value.

  # The fast-checkout experiment: hold checkout to a hard 10s ceiling, and route payments through
  # the processor's slower settlement tier. Increased from 3s to 10s to accommodate the 5s payment
  # gateway latency plus overhead, preventing Lambda timeouts.
  checkout_timeout = var.deployment_profile == "tight-latency-budget" ? 10 : 30
  payment_delay_ms = var.deployment_profile == "tight-latency-budget" ? 5000 : 40

  # Bound spend in lower environments by reserving payment capacity. -1 means no reservation.
  payment_reserved_concurrency = var.deployment_profile == "cost-capped" ? 1 : -1

  # Retry stuck fulfilment sooner, and exercise the slower fulfilment path while doing it.
  worker_timeout           = 60
  queue_visibility_timeout = var.deployment_profile == "fast-redelivery" ? 10 : 360
  worker_processing_ms     = var.deployment_profile == "fast-redelivery" ? 25000 : 200

  # Store credit and gift-card top-ups: an order carrying a value and no line items.
  promo_only_ratio = var.deployment_profile == "promo-pricing" ? 40 : 0

  # The cost-capped profile needs enough simultaneous orders to be a meaningful test of the cap.
  orders_per_run = var.deployment_profile == "cost-capped" ? 25 : var.traffic_orders_per_run

  # The tightened IAM posture from the security review — see iam.tf.
  worker_may_publish = var.deployment_profile != "least-privilege"

  lambda_env_common = {
    PROJECT = var.project
    PROFILE = var.deployment_profile
  }
}

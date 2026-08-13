# Brewline

Order and fulfilment platform for Brewline's direct-to-consumer coffee business.

A customer places an order, we authorise the payment while they wait, and everything after that —
reserving stock, allocating promotions, confirming to the customer — happens asynchronously behind
a queue, so a slow warehouse never holds up a checkout.

```
                    API Gateway
                         │
                         ▼
                   checkout-api ──sync──► payment-gateway
                         │                (card authorisation)
                         │
                         ▼
                   orders (SQS) ──────► order-worker
                         │                    │
                    orders-dlq                ├──► inventory-api    (stock + promo allocation)
                                              └──► notifications    (customer confirmation)
```

Everything is serverless and stateless. There is no database: an order lives in the request, then
in the queue, then in the confirmation. State belongs to the systems of record downstream.

## Services

| Service | What it does |
|---|---|
| [checkout-api](services/checkout_api/) | Public entry point. Authorises payment, then enqueues the order. |
| [payment-gateway](services/payment_gateway/) | Wraps the card processor. Synchronous; the customer is waiting. |
| [order-worker](services/order_worker/) | Drains the queue and fulfils. Everything here runs post-payment. |
| [inventory-api](services/inventory_api/) | Reserves stock and allocates promotions across the basket. |
| [traffic-generator](services/traffic_generator/) | Synthetic orders for non-production environments. |

Every service logs a `correlation_id` on each line and names the downstream it is calling, so one
order can be followed end to end across all four.

## Running the tests

```bash
uv run --with pytest python -m pytest tests/ -q
```

## Deploying

Infrastructure is Terraform, in [terraform/](terraform/). State is remote (S3, with native
locking), so deploys are safe to run from more than one machine.

```bash
cd terraform
terraform init
terraform apply
```

### Deployment profiles

Environments differ by tuning profile rather than by having their own copies of the config.
`standard` is what production runs; the others exist for experiments and lower environments.

| Profile | What it changes |
|---|---|
| `standard` | Balanced defaults |
| `tight-latency-budget` | Hard 3s ceiling on checkout, for the fast-checkout experiment |
| `cost-capped` | Reserves payment concurrency to bound spend |
| `fast-redelivery` | Shorter queue visibility, so stuck fulfilment retries sooner |
| `promo-pricing` | Puts store-credit and gift-card orders into the mix |
| `least-privilege` | The tightened IAM posture from the security review |

```bash
terraform apply -var="deployment_profile=promo-pricing"
terraform output effective_settings          # what that profile resolved to
```

### Turning synthetic traffic off

```bash
terraform apply -var="traffic_enabled=false"
```

## Operations

Alarms notify the platform team's shared SNS topic. They describe symptoms — error rates, latency,
queue age, dead letters — and deliberately do not speculate about causes, because the same symptom
rarely has the same cause twice.

```bash
aws cloudwatch describe-alarms --region eu-central-1 \
  --alarm-name-prefix brewline --state-value ALARM \
  --query 'MetricAlarms[].[AlarmName,StateReason]' --output table

aws logs tail /aws/lambda/brewline-order-worker --region eu-central-1 --follow
```

## Teardown

```bash
cd terraform && terraform destroy
```

The alerting topic is owned by the platform team and looked up rather than created, so destroying
a Brewline environment never removes it.

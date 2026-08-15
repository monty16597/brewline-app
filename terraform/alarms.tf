# We alarm where customers feel it: the checkout path, and the fulfilment queue behind it.
#
# Descriptions state the symptom and stop there, on purpose. An alarm can only report what the
# metric shows — writing a suspected cause into the description ages badly, because the next
# incident with the same symptom usually has a different cause, and by then the text is lying.
# Whoever picks the page up decides what is wrong; the alarm tells them what is happening.

locals {
  alarm_actions = [data.aws_sns_topic.incidents.arn]
}

# ── the symptom every customer-facing failure shows up as ──────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "checkout_errors" {
  alarm_name          = "${var.project}-checkout-api-errors"
  alarm_description   = "Checkout is returning errors to customers. Orders are not being placed."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.checkout.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "checkout_latency" {
  alarm_name        = "${var.project}-checkout-api-latency"
  alarm_description = "Checkout p99 latency is above 2.5s. Customers are waiting on the order form."
  namespace         = "AWS/Lambda"
  metric_name       = "Duration"
  dimensions        = { FunctionName = aws_lambda_function.checkout.function_name }
  extended_statistic = "p99"
  period             = 60
  evaluation_periods = 1

  # Deliberately BELOW the shortest checkout timeout any profile sets (3s), not equal to it.
  # A Lambda that times out reports Duration capped at exactly its timeout — measured p99 came
  # back as 2999.98ms against a 3s budget — so a threshold of 3000 with GreaterThanThreshold can
  # never be crossed by the very failure it exists to catch. The SLO is a fixed customer-latency
  # promise; it has to sit under the timeout to be observable at all.
  threshold = 2500
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${var.project}-api-5xx"
  alarm_description   = "The public API is serving 5xx responses on /checkout."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = aws_apigatewayv2_api.brewline.id }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ── the symptom for anything that goes wrong after the customer has been told "yes" ────────────
resource "aws_cloudwatch_metric_alarm" "worker_errors" {
  alarm_name          = "${var.project}-order-worker-errors"
  alarm_description   = "Order fulfilment is failing. Payments have been authorised for orders that are not being fulfilled."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.worker.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ── the queue: the only place a duplicate-delivery fault is visible at all ──────────────────────
resource "aws_cloudwatch_metric_alarm" "orders_backlog" {
  alarm_name          = "${var.project}-orders-queue-backlog"
  alarm_description   = "Orders are sitting in the fulfilment queue longer than two minutes."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.orders.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 120
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "orders_dlq" {
  alarm_name          = "${var.project}-orders-dlq-not-empty"
  alarm_description   = "Orders have been abandoned to the dead-letter queue after repeated delivery failures."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.orders_dlq.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

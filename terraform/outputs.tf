output "api_url" {
  description = "The public checkout endpoint."
  value       = "${aws_apigatewayv2_api.brewline.api_endpoint}/checkout"
}

output "deployment_profile" {
  description = "Which tuning profile this environment is running."
  value       = var.deployment_profile
}

output "incident_topic" {
  description = "Where the alarms publish — the pipeline's front door."
  value       = data.aws_sns_topic.incidents.arn
}

output "alarms" {
  description = "Every alarm on this environment."
  value = [
    aws_cloudwatch_metric_alarm.checkout_errors.alarm_name,
    aws_cloudwatch_metric_alarm.checkout_latency.alarm_name,
    aws_cloudwatch_metric_alarm.api_5xx.alarm_name,
    aws_cloudwatch_metric_alarm.worker_errors.alarm_name,
    aws_cloudwatch_metric_alarm.orders_backlog.alarm_name,
    aws_cloudwatch_metric_alarm.orders_dlq.alarm_name,
  ]
}

output "log_groups" {
  description = "Service logs, in the order a request travels through them."
  value = {
    api       = aws_cloudwatch_log_group.api.name
    checkout  = "/aws/lambda/${local.services.checkout}"
    payment   = "/aws/lambda/${local.services.payment}"
    worker    = "/aws/lambda/${local.services.worker}"
    inventory = "/aws/lambda/${local.services.inventory}"
    traffic   = "/aws/lambda/${local.services.traffic}"
  }
}

output "effective_settings" {
  description = "The tuning values this profile resolved to."
  value = {
    checkout_timeout_seconds     = local.checkout_timeout
    payment_delay_ms             = local.payment_delay_ms
    payment_reserved_concurrency = local.payment_reserved_concurrency
    queue_visibility_seconds     = local.queue_visibility_timeout
    worker_timeout_seconds       = local.worker_timeout
    worker_processing_ms         = local.worker_processing_ms
    promo_only_order_percent     = local.promo_only_ratio
    worker_may_publish_sns       = local.worker_may_publish
    orders_per_run               = local.orders_per_run
  }
}

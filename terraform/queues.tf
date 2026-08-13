resource "aws_sqs_queue" "orders_dlq" {
  name                      = "${var.project}-orders-dlq"
  message_retention_seconds = 86400
}

resource "aws_sqs_queue" "orders" {
  name = "${var.project}-orders"

  # AWS guidance is a visibility timeout of at least the consumer's function timeout, and in
  # practice 6x it. 360 against a 60s worker follows that. The fast-redelivery profile lowers it
  # so stuck fulfilment is retried sooner.
  visibility_timeout_seconds = local.queue_visibility_timeout

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orders_dlq.arn
    maxReceiveCount     = 3
  })
}

# Customer-facing order confirmations. Separate from the platform team's alerting topic: this one
# belongs to Brewline and carries customer messages, not operational alerts.
resource "aws_sns_topic" "notifications" {
  name = "${var.project}-notifications"
}

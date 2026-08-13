data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "service" {
  for_each           = local.services
  name               = "${each.value}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "basic_logging" {
  for_each   = local.services
  role       = aws_iam_role.service[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ── checkout: calls payment, enqueues the order ────────────────────────────────────────────────
data "aws_iam_policy_document" "checkout" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.payment.arn]
  }
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.orders.arn]
  }
}

resource "aws_iam_role_policy" "checkout" {
  name   = "${local.services.checkout}-policy"
  role   = aws_iam_role.service["checkout"].id
  policy = data.aws_iam_policy_document.checkout.json
}

# ── worker: drains the queue, calls inventory, notifies the customer ───────────────────────────
data "aws_iam_policy_document" "worker" {
  statement {
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.orders.arn]
  }

  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.inventory.arn]
  }

  # Withheld under the least-privilege profile, which the security review asked for: the worker
  # keeps only the grants needed to drain the queue and reserve stock.
  dynamic "statement" {
    for_each = local.worker_may_publish ? [1] : []
    content {
      actions   = ["sns:Publish"]
      resources = [aws_sns_topic.notifications.arn]
    }
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "${local.services.worker}-policy"
  role   = aws_iam_role.service["worker"].id
  policy = data.aws_iam_policy_document.worker.json
}

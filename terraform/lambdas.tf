data "archive_file" "service" {
  for_each    = local.services
  type        = "zip"
  source_dir  = "${path.module}/../services/${local.service_dirs[each.key]}"
  output_path = "${path.module}/.build/${each.key}.zip"
}

resource "aws_cloudwatch_log_group" "service" {
  for_each          = local.services
  name              = "/aws/lambda/${each.value}"
  retention_in_days = var.log_retention_days
}

# ── checkout ───────────────────────────────────────────────────────────────────────────────────
resource "aws_lambda_function" "checkout" {
  function_name    = local.services.checkout
  role             = aws_iam_role.service["checkout"].arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.service["checkout"].output_path
  source_code_hash = data.archive_file.service["checkout"].output_base64sha256

  # The customer is waiting on this call, so the budget is deliberately tight.
  timeout     = local.checkout_timeout
  memory_size = 256

  environment {
    variables = merge(local.lambda_env_common, {
      PAYMENT_FUNCTION = local.services.payment
      ORDERS_QUEUE_URL = aws_sqs_queue.orders.url
    })
  }

  depends_on = [aws_cloudwatch_log_group.service]
}

# ── payment ────────────────────────────────────────────────────────────────────────────────────
resource "aws_lambda_function" "payment" {
  function_name    = local.services.payment
  role             = aws_iam_role.service["payment"].arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.service["payment"].output_path
  source_code_hash = data.archive_file.service["payment"].output_base64sha256

  timeout     = 30
  memory_size = 256

  # -1 means "no reservation". The cost-capped profile reserves a small fixed capacity here.
  reserved_concurrent_executions = local.payment_reserved_concurrency

  environment {
    variables = merge(local.lambda_env_common, {
      PAYMENT_DELAY_MS = tostring(local.payment_delay_ms)
    })
  }

  depends_on = [aws_cloudwatch_log_group.service]
}

# ── inventory ──────────────────────────────────────────────────────────────────────────────────
resource "aws_lambda_function" "inventory" {
  function_name    = local.services.inventory
  role             = aws_iam_role.service["inventory"].arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.service["inventory"].output_path
  source_code_hash = data.archive_file.service["inventory"].output_base64sha256

  timeout     = 30
  memory_size = 256

  environment {
    variables = merge(local.lambda_env_common, { WAREHOUSE_ID = "wh-${var.region}a" })
  }

  depends_on = [aws_cloudwatch_log_group.service]
}

# ── worker ─────────────────────────────────────────────────────────────────────────────────────
resource "aws_lambda_function" "worker" {
  function_name    = local.services.worker
  role             = aws_iam_role.service["worker"].arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.service["worker"].output_path
  source_code_hash = data.archive_file.service["worker"].output_base64sha256

  # Fulfilment does real work — packing, labelling, courier handover — so it gets a long budget.
  timeout     = local.worker_timeout
  memory_size = 256

  environment {
    variables = merge(local.lambda_env_common, {
      INVENTORY_FUNCTION  = local.services.inventory
      NOTIFICATIONS_TOPIC = aws_sns_topic.notifications.arn
      PROCESSING_MS       = tostring(local.worker_processing_ms)
    })
  }

  depends_on = [aws_cloudwatch_log_group.service]
}

resource "aws_lambda_event_source_mapping" "orders" {
  event_source_arn = aws_sqs_queue.orders.arn
  function_name    = aws_lambda_function.worker.arn
  batch_size       = 1
}

# ── traffic generator ──────────────────────────────────────────────────────────────────────────
resource "aws_lambda_function" "traffic" {
  function_name    = local.services.traffic
  role             = aws_iam_role.service["traffic"].arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.service["traffic"].output_path
  source_code_hash = data.archive_file.service["traffic"].output_base64sha256

  # Long enough to outlast a slow payment tier without the generator itself timing out.
  timeout     = 120
  memory_size = 256

  environment {
    variables = merge(local.lambda_env_common, {
      API_URL          = "${aws_apigatewayv2_api.brewline.api_endpoint}/checkout"
      ORDERS_PER_RUN   = tostring(local.orders_per_run)
      PROMO_ONLY_RATIO = tostring(local.promo_only_ratio)
    })
  }

  depends_on = [aws_cloudwatch_log_group.service]
}

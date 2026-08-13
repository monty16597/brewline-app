resource "aws_cloudwatch_event_rule" "traffic" {
  name                = "${var.project}-traffic"
  description         = "Places Brewline orders on a schedule so the estate has something to fail at."
  schedule_expression = var.traffic_rate
  state               = var.traffic_enabled ? "ENABLED" : "DISABLED"
}

resource "aws_cloudwatch_event_target" "traffic" {
  rule      = aws_cloudwatch_event_rule.traffic.name
  target_id = "traffic-generator"
  arn       = aws_lambda_function.traffic.arn
}

resource "aws_lambda_permission" "events_invoke_traffic" {
  statement_id  = "AllowInvokeFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.traffic.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.traffic.arn
}

resource "aws_apigatewayv2_api" "brewline" {
  name          = "${var.project}-api"
  protocol_type = "HTTP"
  description   = "Brewline public checkout API — the only entry point customers touch."
}

resource "aws_apigatewayv2_integration" "checkout" {
  api_id                 = aws_apigatewayv2_api.brewline.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.checkout.invoke_arn
  payload_format_version = "2.0"

  # The gateway must outlast the function, or API Gateway gives up first and the incident becomes
  # a gateway timeout with no Lambda error behind it — a much worse trail to follow.
  timeout_milliseconds = 30000
}

resource "aws_apigatewayv2_route" "checkout" {
  api_id    = aws_apigatewayv2_api.brewline.id
  route_key = "POST /checkout"
  target    = "integrations/${aws_apigatewayv2_integration.checkout.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.brewline.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId               = "$context.requestId"
      httpMethod              = "$context.httpMethod"
      path                    = "$context.path"
      status                  = "$context.status"
      responseLength          = "$context.responseLength"
      responseLatency         = "$context.responseLatency"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${var.project}-api"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_permission" "api_invoke_checkout" {
  statement_id  = "AllowInvokeFromHttpApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.checkout.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.brewline.execution_arn}/*/*"
}

"""Brewline checkout — the public order entry point.

Authorises payment synchronously, then hands the order to the fulfilment queue. We do not enqueue
an order we could not charge for, so the payment call blocks the response and the customer waits
on it.

Every log line carries the correlation id and names the downstream it was talking to, so a single
order can be followed across services.
"""
from __future__ import annotations

import json
import logging
import os
import time
import uuid

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger("brewline.checkout")
# Lambda pre-installs a root handler, so logging.basicConfig() returns early and the effective
# level stays at WARNING — every log.info below would silently vanish. Set it on our own logger.
log.setLevel(logging.INFO)

lambda_client = boto3.client("lambda")
sqs = boto3.client("sqs")

PAYMENT_FUNCTION = os.environ["PAYMENT_FUNCTION"]
ORDERS_QUEUE_URL = os.environ["ORDERS_QUEUE_URL"]


def _authorise(order: dict, correlation_id: str) -> dict:
    """Ask the payment gateway to authorise. Synchronous on purpose — we will not enqueue an
    order we could not charge for."""
    log.info("correlation_id=%s calling downstream=%s action=authorise amount_cents=%s",
             correlation_id, PAYMENT_FUNCTION, order.get("total_cents"))
    started = time.monotonic()
    response = lambda_client.invoke(
        FunctionName=PAYMENT_FUNCTION,
        InvocationType="RequestResponse",
        Payload=json.dumps({"order": order, "correlation_id": correlation_id}).encode(),
    )
    elapsed_ms = int((time.monotonic() - started) * 1000)
    payload = json.loads(response["Payload"].read() or b"{}")

    # A throttled or erroring callee surfaces here as FunctionError, not as an exception.
    if response.get("FunctionError"):
        log.error("correlation_id=%s downstream=%s FAILED in %sms error=%s",
                  correlation_id, PAYMENT_FUNCTION, elapsed_ms, payload)
        raise RuntimeError(f"payment gateway rejected the call: {payload}")

    log.info("correlation_id=%s downstream=%s authorised in %sms",
             correlation_id, PAYMENT_FUNCTION, elapsed_ms)
    return payload


def handler(event, context):
    correlation_id = str(uuid.uuid4())[:8]
    body = json.loads(event.get("body") or "{}")

    order = {
        "order_id": body.get("order_id") or str(uuid.uuid4())[:12],
        "customer_id": body.get("customer_id", "cust-unknown"),
        "items": body.get("items", []),
        "total_cents": body.get("total_cents", 0),
        "promo_code": body.get("promo_code"),
    }
    log.info("correlation_id=%s order_id=%s items=%d total_cents=%s promo=%s",
             correlation_id, order["order_id"], len(order["items"]),
             order["total_cents"], order["promo_code"])

    try:
        authorisation = _authorise(order, correlation_id)
    except lambda_client.exceptions.TooManyRequestsException as exc:
        # Capacity, not a failure — worth its own branch so the log says which it was.
        log.error("correlation_id=%s downstream=%s THROTTLED: %s",
                  correlation_id, PAYMENT_FUNCTION, exc)
        return _response(503, {"error": "payment temporarily unavailable",
                               "correlation_id": correlation_id})
    except ClientError as exc:
        log.exception("correlation_id=%s downstream=%s client error", correlation_id,
                      PAYMENT_FUNCTION)
        return _response(502, {"error": str(exc), "correlation_id": correlation_id})

    sqs.send_message(
        QueueUrl=ORDERS_QUEUE_URL,
        MessageBody=json.dumps({
            "order": order,
            "authorisation": authorisation,
            "correlation_id": correlation_id,
        }),
    )
    log.info("correlation_id=%s order_id=%s enqueued for fulfilment",
             correlation_id, order["order_id"])

    return _response(202, {"order_id": order["order_id"], "correlation_id": correlation_id})


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }

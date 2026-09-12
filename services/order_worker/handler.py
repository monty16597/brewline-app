"""Brewline order worker — fulfilment.

Drains the orders queue, reserves stock, and confirms to the customer. Everything here runs after
payment has already been taken, so a failure at this stage means a customer has been charged for
an order that is not on its way — worth being loud about in the logs.
"""
from __future__ import annotations

import json
import logging
import os
import time

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger("brewline.worker")
# Lambda pre-installs a root handler, so logging.basicConfig() returns early and the effective
# level stays at WARNING — every log.info below would silently vanish. Set it on our own logger.
log.setLevel(logging.INFO)

lambda_client = boto3.client("lambda")
sns = boto3.client("sns")

INVENTORY_FUNCTION = os.environ["INVENTORY_FUNCTION"]
NOTIFICATIONS_TOPIC = os.environ["NOTIFICATIONS_TOPIC"]
PROCESSING_MS = int(os.environ.get("PROCESSING_MS", "200"))

# Retry configuration for transient failures
MAX_RETRIES = 3
RETRY_BACKOFF_SECONDS = [1, 2, 4]  # Exponential backoff: 1s, 2s, 4s


def _reserve_stock(order: dict, correlation_id: str) -> dict:
    """Reserve stock with exponential backoff retry logic for transient failures."""
    last_error = None
    
    for attempt in range(MAX_RETRIES):
        try:
            log.info("correlation_id=%s calling downstream=%s action=reserve attempt=%d",
                     correlation_id, INVENTORY_FUNCTION, attempt + 1)
            response = lambda_client.invoke(
                FunctionName=INVENTORY_FUNCTION,
                InvocationType="RequestResponse",
                Payload=json.dumps({"order": order, "correlation_id": correlation_id}).encode(),
            )
            payload = json.loads(response["Payload"].read() or b"{}")

            if response.get("FunctionError"):
                # Relay the callee's own error text. Swallowing it here would turn a specific failure
                # into an unhelpful "the worker is failing".
                log.error("correlation_id=%s downstream=%s raised %s: %s",
                          correlation_id, INVENTORY_FUNCTION,
                          payload.get("errorType"), payload.get("errorMessage"))
                raise RuntimeError(
                    f"{INVENTORY_FUNCTION} failed: {payload.get('errorType')}: "
                    f"{payload.get('errorMessage')}"
                )
            return payload
        except (TimeoutError, ClientError) as exc:
            last_error = exc
            if attempt < MAX_RETRIES - 1:
                backoff_seconds = RETRY_BACKOFF_SECONDS[attempt]
                log.warning("correlation_id=%s downstream=%s transient failure attempt=%d: %s "
                            "retrying in %ds",
                            correlation_id, INVENTORY_FUNCTION, attempt + 1, exc, backoff_seconds)
                time.sleep(backoff_seconds)
            else:
                log.error("correlation_id=%s downstream=%s failed after %d attempts: %s",
                          correlation_id, INVENTORY_FUNCTION, MAX_RETRIES, exc)
    
    # All retries exhausted
    raise last_error or RuntimeError(f"Failed to reserve stock after {MAX_RETRIES} attempts")


def _notify(order: dict, correlation_id: str) -> None:
    log.info("correlation_id=%s publishing confirmation topic=%s",
             correlation_id, NOTIFICATIONS_TOPIC)
    sns.publish(
        TopicArn=NOTIFICATIONS_TOPIC,
        Subject=f"Order {order.get('order_id')} confirmed",
        Message=json.dumps({"order_id": order.get("order_id"),
                            "correlation_id": correlation_id}),
    )


def handler(event, context):
    for record in event.get("Records", []):
        body = json.loads(record["body"])
        order = body.get("order", {})
        correlation_id = body.get("correlation_id", "unknown")

        # Redelivery is invisible unless someone says so out loud. `approximateReceiveCount`
        # above 1 means this exact order has been handed to a worker before.
        receive_count = int(record.get("attributes", {}).get("ApproximateReceiveCount", 1))
        if receive_count > 1:
            log.warning("correlation_id=%s order_id=%s DUPLICATE DELIVERY receive_count=%s "
                        "- this order is being fulfilled more than once",
                        correlation_id, order.get("order_id"), receive_count)

        log.info("correlation_id=%s order_id=%s fulfilment started receive_count=%s",
                 correlation_id, order.get("order_id"), receive_count)

        reservation = _reserve_stock(order, correlation_id)

        # Packing, labelling, handing to the courier.
        time.sleep(PROCESSING_MS / 1000.0)

        try:
            _notify(order, correlation_id)
        except ClientError as exc:
            log.error("correlation_id=%s could not publish confirmation: %s", correlation_id, exc)
            raise

        log.info("correlation_id=%s order_id=%s fulfilled warehouse=%s",
                 correlation_id, order.get("order_id"), reservation.get("warehouse"))

    return {"processed": len(event.get("Records", []))}

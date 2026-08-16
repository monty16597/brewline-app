"""Brewline payment gateway — card authorisation.

Wraps the card processor. Authorisation is synchronous and the caller is waiting, so this service
reports how long the processor took on every call: settlement latency varies by tier and by time
of day, and it is the number worth having when a checkout complaint comes in.
"""
from __future__ import annotations

import json
import logging
import os
import time

import requests

log = logging.getLogger("brewline.payment")
# Lambda pre-installs a root handler, so logging.basicConfig() returns early and the effective
# level stays at WARNING — every log.info below would silently vanish. Set it on our own logger.
log.setLevel(logging.INFO)

# Observed round-trip to the card processor for this environment's settlement tier.
DELAY_MS = int(os.environ.get("PAYMENT_DELAY_MS", "40"))

# HTTP timeout for payment processor API calls (2 seconds).
# This ensures we fail fast if the processor is slow, rather than hanging until the Lambda timeout.
HTTP_TIMEOUT_SECONDS = 2.0

# Payment processor endpoint (can be overridden via environment variable for testing).
PROCESSOR_ENDPOINT = os.environ.get("PROCESSOR_ENDPOINT", "http://localhost:9999/authorize")


def authorise(total_cents: int, correlation_id: str) -> dict:
    log.info("correlation_id=%s authorising amount_cents=%s upstream_latency_ms=%s",
             correlation_id, total_cents, DELAY_MS)

    # The call out to the card processor with a timeout to prevent hanging.
    try:
        started = time.monotonic()
        response = requests.post(
            PROCESSOR_ENDPOINT,
            json={"amount_cents": total_cents, "correlation_id": correlation_id},
            timeout=HTTP_TIMEOUT_SECONDS,
        )
        response.raise_for_status()
        elapsed_ms = int((time.monotonic() - started) * 1000)
        processor_latency_ms = elapsed_ms
    except requests.exceptions.Timeout:
        log.error("correlation_id=%s payment processor timeout after %s seconds",
                  correlation_id, HTTP_TIMEOUT_SECONDS)
        raise RuntimeError(f"payment processor timeout after {HTTP_TIMEOUT_SECONDS}s") from None
    except requests.exceptions.ConnectionError as exc:
        log.error("correlation_id=%s payment processor connection error: %s",
                  correlation_id, exc)
        raise RuntimeError(f"payment processor connection error: {exc}") from exc
    except requests.exceptions.RequestException as exc:
        log.error("correlation_id=%s payment processor error: %s", correlation_id, exc)
        raise RuntimeError(f"payment processor error: {exc}") from exc

    return {
        "authorised": True,
        "auth_code": f"AUTH-{abs(hash(correlation_id)) % 1_000_000:06d}",
        "amount_cents": total_cents,
        "processor_latency_ms": processor_latency_ms,
    }


def handler(event, context):
    correlation_id = event.get("correlation_id", "unknown")
    order = event.get("order", {})

    started = time.monotonic()
    result = authorise(order.get("total_cents", 0), correlation_id)
    elapsed_ms = int((time.monotonic() - started) * 1000)

    remaining_ms = context.get_remaining_time_in_millis() if context else -1
    log.info("correlation_id=%s authorised in %sms auth_code=%s remaining_budget_ms=%s",
             correlation_id, elapsed_ms, result["auth_code"], remaining_ms)

    return result


if __name__ == "__main__":  # pragma: no cover - local smoke check
    print(json.dumps(handler({"order": {"total_cents": 1200}, "correlation_id": "local"}, None)))

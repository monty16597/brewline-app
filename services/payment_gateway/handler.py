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

log = logging.getLogger("brewline.payment")
# Lambda pre-installs a root handler, so logging.basicConfig() returns early and the effective
# level stays at WARNING — every log.info below would silently vanish. Set it on our own logger.
log.setLevel(logging.INFO)

# Observed round-trip to the card processor for this environment's settlement tier.
DELAY_MS = int(os.environ.get("PAYMENT_DELAY_MS", "40"))


def authorise(total_cents: int, correlation_id: str) -> dict:
    log.info("correlation_id=%s authorising amount_cents=%s upstream_latency_ms=%s",
             correlation_id, total_cents, DELAY_MS)

    # The call out to the card processor.
    time.sleep(DELAY_MS / 1000.0)

    return {
        "authorised": True,
        "auth_code": f"AUTH-{abs(hash(correlation_id)) % 1_000_000:06d}",
        "amount_cents": total_cents,
        "processor_latency_ms": DELAY_MS,
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

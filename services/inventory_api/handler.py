"""Brewline inventory — stock reservation and promo allocation.

Reserves the goods on a confirmed order and works out what each line costs after any promotion,
so the fulfilment note and the customer's receipt agree on the price of every item.
"""
from __future__ import annotations

import logging
import os

log = logging.getLogger("brewline.inventory")
# Lambda pre-installs a root handler, so logging.basicConfig() returns early and the effective
# level stays at WARNING — every log.info below would silently vanish. Set it on our own logger.
log.setLevel(logging.INFO)

WAREHOUSE = os.environ.get("WAREHOUSE_ID", "wh-eu-central-1a")


def allocate_discount(total_cents: int, items: list[dict]) -> int:
    """Per-item share of the promo discount, in cents.

    A basket of 4 items sharing a 400-cent discount takes 100 cents off each.
    """
    if len(items) == 0:
        return 0  # No items, no discount to allocate
    discount_cents = total_cents // 10  # flat 10% promo
    return discount_cents // len(items)


def reserve(order: dict, correlation_id: str) -> dict:
    items = order.get("items", [])
    total_cents = order.get("total_cents", 0)

    log.info("correlation_id=%s reserving order_id=%s items=%d warehouse=%s",
             correlation_id, order.get("order_id"), len(items), WAREHOUSE)

    per_item_discount = allocate_discount(total_cents, items)

    reservations = [
        {"sku": item.get("sku"), "qty": item.get("qty", 1), "discount_cents": per_item_discount}
        for item in items
    ]
    log.info("correlation_id=%s reserved %d line(s) discount_per_item_cents=%s",
             correlation_id, len(reservations), per_item_discount)

    return {"warehouse": WAREHOUSE, "reservations": reservations}


def handler(event, context):
    correlation_id = event.get("correlation_id", "unknown")
    order = event.get("order", {})
    return reserve(order, correlation_id)

"""Brewline synthetic orders.

Places orders against the public API on a schedule, the same way a customer's browser would, so
non-production environments always have representative traffic to look at. Orders are sent
concurrently to mirror real checkout bursts.

`PROMO_ONLY_RATIO` controls how much of the mix is store credit and gift-card top-ups.
"""
from __future__ import annotations

import json
import logging
import os
import random
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

log = logging.getLogger("brewline.traffic")
# Lambda pre-installs a root handler, so logging.basicConfig() returns early and the effective
# level stays at WARNING — every log.info below would silently vanish. Set it on our own logger.
log.setLevel(logging.INFO)

API_URL = os.environ["API_URL"]
ORDERS_PER_RUN = int(os.environ.get("ORDERS_PER_RUN", "5"))
PROMO_ONLY_RATIO = int(os.environ.get("PROMO_ONLY_RATIO", "0"))  # percent

SKUS = ["SKU-COFFEE-1KG", "SKU-MUG-350ML", "SKU-FILTER-V60", "SKU-GRINDER-C40"]


def _build_order(index: int) -> dict:
    """A normal basket, or a promo-only order: store credit and gift-card top-ups carry a
    value and no goods."""
    if random.randint(1, 100) <= PROMO_ONLY_RATIO:
        return {
            "order_id": f"promo-{index}-{random.randint(1000, 9999)}",
            "customer_id": f"cust-{random.randint(1, 500)}",
            "items": [],
            "total_cents": random.choice([2500, 5000, 10000]),
            "promo_code": "STORECREDIT",
        }

    items = [{"sku": random.choice(SKUS), "qty": random.randint(1, 3)}
             for _ in range(random.randint(1, 4))]
    return {
        "order_id": f"ord-{index}-{random.randint(1000, 9999)}",
        "customer_id": f"cust-{random.randint(1, 500)}",
        "items": items,
        "total_cents": sum(item["qty"] * 1200 for item in items),
        "promo_code": None,
    }


def _place(order: dict) -> int:
    request = urllib.request.Request(
        API_URL,
        data=json.dumps(order).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            return response.status
    except urllib.error.HTTPError as exc:
        # An expected outcome, not a generator failure: a 5xx here is the incident.
        log.warning("order_id=%s rejected status=%s", order["order_id"], exc.code)
        return exc.code
    except Exception as exc:  # noqa: BLE001 - synthetic traffic must never be the thing that fails
        log.warning("order_id=%s could not be placed: %s", order["order_id"], exc)
        return 0


def handler(event, context):
    orders = [_build_order(i) for i in range(ORDERS_PER_RUN)]
    promo_only = sum(1 for order in orders if not order["items"])
    log.info("placing %d orders (%d promo-only) against %s", len(orders), promo_only, API_URL)

    with ThreadPoolExecutor(max_workers=min(ORDERS_PER_RUN, 25)) as pool:
        statuses = list(pool.map(_place, orders))

    tally: dict[int, int] = {}
    for status in statuses:
        tally[status] = tally.get(status, 0) + 1
    log.info("run complete: %s", {str(k): v for k, v in sorted(tally.items())})

    return {"placed": len(orders), "promo_only": promo_only, "statuses": tally}

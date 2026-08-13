"""Tests for inventory's promo allocation."""
from __future__ import annotations

from services.inventory_api.handler import allocate_discount, reserve


def test_a_four_item_basket_splits_the_discount_evenly() -> None:
    items = [{"sku": f"SKU-{i}", "qty": 1} for i in range(4)]
    # 10% of 4800 is 480, split four ways.
    assert allocate_discount(4800, items) == 120


def test_a_single_item_basket_takes_the_whole_discount() -> None:
    assert allocate_discount(1200, [{"sku": "SKU-COFFEE-1KG", "qty": 1}]) == 120


def test_the_discount_is_a_whole_number_of_cents() -> None:
    """Three items into a 10% discount does not divide cleanly; we never emit fractional cents."""
    items = [{"sku": f"SKU-{i}", "qty": 1} for i in range(3)]
    assert allocate_discount(1000, items) == 33


def test_a_free_order_discounts_nothing() -> None:
    assert allocate_discount(0, [{"sku": "SKU-FREEBIE", "qty": 1}]) == 0


def test_reserve_returns_one_reservation_per_line() -> None:
    order = {
        "order_id": "ord-1",
        "total_cents": 2400,
        "items": [{"sku": "SKU-MUG-350ML", "qty": 2}, {"sku": "SKU-FILTER-V60", "qty": 1}],
    }
    result = reserve(order, "test-corr")

    assert len(result["reservations"]) == 2
    assert result["reservations"][0]["sku"] == "SKU-MUG-350ML"
    assert all(r["discount_cents"] == 120 for r in result["reservations"])

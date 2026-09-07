from dataclasses import dataclass


@dataclass(frozen=True)
class CheckoutResult:
    """金額はすべて整数の円。subtotalは割引適用後。"""

    subtotal: int
    shipping: int
    total: int

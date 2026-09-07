from contracts import CheckoutResult


FREE_SHIPPING_THRESHOLD = 5_000
SHIPPING_FEE = 500


def calculate_total(prices: list[int], discount: int = 0) -> CheckoutResult:
    """割引後の小計で送料を決める。空の注文には送料を請求しない。"""
    if discount < 0 or any(price < 0 for price in prices):
        raise ValueError("金額は0以上で指定してください")

    subtotal = max(0, sum(prices) - discount)

    if not prices or subtotal >= FREE_SHIPPING_THRESHOLD:
        shipping = 0
    else:
        shipping = SHIPPING_FEE

    return CheckoutResult(
        subtotal=subtotal,
        shipping=shipping,
        total=subtotal + shipping,
    )

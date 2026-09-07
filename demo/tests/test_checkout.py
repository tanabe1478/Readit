import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from checkout import calculate_total


class CheckoutTests(unittest.TestCase):
    def test_exact_threshold_is_free(self):
        self.assertEqual(calculate_total([5_000]).shipping, 0)

    def test_below_threshold_has_shipping(self):
        self.assertEqual(calculate_total([4_999]).total, 5_499)

    def test_discount_affects_shipping(self):
        self.assertEqual(calculate_total([5_000], discount=1).shipping, 500)

    def test_empty_order(self):
        self.assertEqual(calculate_total([]).total, 0)

    def test_negative_price_is_rejected(self):
        with self.assertRaises(ValueError):
            calculate_total([-1])

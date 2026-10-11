from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PiPackageTests(unittest.TestCase):
    def test_packaged_skill_is_portable_and_matches_the_source_skill(self):
        source = ROOT / "skills" / "readit-guide" / "SKILL.md"
        packaged = ROOT / "integrations" / "pi" / "skills" / "readit-guide" / "SKILL.md"

        self.assertTrue(packaged.is_file())
        self.assertFalse(packaged.is_symlink())
        self.assertEqual(packaged.read_bytes(), source.read_bytes())


if __name__ == "__main__":
    unittest.main()

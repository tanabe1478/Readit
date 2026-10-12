"""The documents that teach a model the tools must match the tools."""
import importlib.util
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("readit_mcp", ROOT / "tools/readit_mcp.py")
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)

TOOLS = {tool["name"]: tool for tool in mcp.TOOLS}
SKILL = (ROOT / "skills/readit-guide/SKILL.md").read_text(encoding="utf-8")
DOCS = {
    path: (ROOT / path).read_text(encoding="utf-8")
    for path in ["skills/readit-guide/SKILL.md", "docs/mcp.md", "integrations/pi/README.md", "README.md", "web/README.md"]
}
# Names that look like tools but are programs or files.
NOT_TOOLS = {"readit_mcp", "readit_wait", "readit_e2e"}


class DocsTests(unittest.TestCase):
    def test_every_tool_is_explained_in_the_skill_and_the_mcp_guide(self):
        for name in TOOLS:
            self.assertIn(name, SKILL, f"{name} is missing from the skill")
            self.assertIn(name, DOCS["docs/mcp.md"], f"{name} is missing from docs/mcp.md")

    def test_documents_name_only_real_tools(self):
        for path, text in DOCS.items():
            for match in re.finditer(r"readit_[a-z_]+", text):
                name = match.group().rstrip("_")
                self.assertTrue(name in TOOLS or name in NOT_TOOLS, f"{path} names unknown tool {name}")

    def test_documented_calls_use_real_parameters(self):
        calls = re.findall(r"`(readit_[a-z_]+)\(([^)`]*)\)`", SKILL)
        self.assertGreater(len(calls), 5)
        for name, arguments in calls:
            self.assertIn(name, TOOLS, f"the skill calls unknown tool {name}")
            properties = TOOLS[name]["inputSchema"]["properties"]
            for argument in filter(None, (a.strip() for a in arguments.split(","))):
                parameter = re.split(r"[=:]", argument)[0].strip()
                self.assertIn(parameter, properties, f"{name} has no parameter {parameter}")

    def test_skill_limits_follow_the_schema(self):
        self.assertEqual(mcp.STEPS["maxItems"], 32)
        self.assertIn("1–32 steps", SKILL)
        chapters = mcp.OVERVIEW["properties"]["chapters"]
        self.assertEqual((chapters["minItems"], chapters["maxItems"]), (1, 16))
        self.assertIn("1–16 `chapters`", SKILL)
        self.assertEqual(mcp.OVERVIEW["properties"]["claims"]["maxItems"], 8)
        self.assertIn("`overview.claims` (max 8)", SKILL)
        evidence = mcp.CLAIM["properties"]["evidence"]
        self.assertEqual((evidence["minItems"], evidence["maxItems"]), (1, 8))
        self.assertIn("1–8 `evidence` anchors", SKILL)
        self.assertEqual(mcp.READER_CONTEXT["properties"]["known"]["maxItems"], 16)
        self.assertEqual(mcp.READER_CONTEXT["properties"]["focus"]["maxItems"], 8)
        self.assertIn("`overview.reader_context.known` (max 16)", SKILL)
        self.assertIn("`focus` (max 8)", SKILL)
        self.assertEqual(mcp.KINDS, ["explanation", "hypothesis", "prediction", "verification"])
        for kind in mcp.KINDS[1:]:
            self.assertIn(f'`kind: "{kind}"`', SKILL)

    def test_required_parameters_are_named_in_the_skill_calls(self):
        # When the skill shows a call with arguments, every required parameter is in it.
        for name, arguments in re.findall(r"`(readit_[a-z_]+)\(([^)`]*)\)`", SKILL):
            if not arguments.strip() or "=" in arguments:
                continue
            given = {a.strip() for a in arguments.split(",")}
            for required in TOOLS[name]["inputSchema"]["required"]:
                self.assertIn(required, given, f"the skill's {name}(...) omits required {required}")


if __name__ == "__main__":
    unittest.main()

"""Exercise documentation failures that would otherwise reach published docs."""
import tempfile
from pathlib import Path
import unittest

import docs_checks


class DocumentationChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "doc").mkdir()
        (self.root / "README.md").write_text("# Test\n")

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(exist_ok=True, parents=True)
        target.write_text(text)
        return target

    def test_nested_guide_links_and_duplicate_heading_ids(self):
        self.write("README.md", "# Test\n\n[Guide](doc/guide.md#usage-1)\n")
        self.write("doc/guide.md", "# Guide\n\n## Usage\n\n## Usage\n\n[Home](../README.md)\n")
        self.assertEqual(docs_checks.markdown_errors(self.root), [])

    def test_missing_screenshot_is_reported(self):
        self.write("README.md", "# Test\n\n![Actual UI](doc/missing.png)\n")
        self.assertTrue(any("missing target" in issue for issue in docs_checks.markdown_errors(self.root)))

    def test_moved_heading_is_reported(self):
        self.write("README.md", "# Test\n\n[Options](doc/guide.md#options)\n")
        self.write("doc/guide.md", "# Guide\n\n## Workflow\n")
        self.assertTrue(any("missing heading" in issue for issue in docs_checks.markdown_errors(self.root)))

    def test_link_examples_in_code_are_not_navigation(self):
        self.write("README.md", "# Test\n\n```markdown\n[example](missing.md)\n```\n\n`[inline](missing.md)`\n")
        self.assertEqual(docs_checks.markdown_errors(self.root), [])

    def help(self, extra=""):
        body = "*test.txt*\tTest help\n\n"
        for suffix in ("", "-quickstart", "-commands", "-options", "-api", "-lifecycle", "-troubleshooting"):
            body += "*test" + suffix + "*\n"
        body += extra + "\nvim:tw=78:ts=8:noet:ft=help:norl:\n"
        self.write("doc/test.txt", body)

    def test_complete_root_and_section_tags(self):
        self.help()
        errors, files = docs_checks.help_errors(self.root, "test")
        self.assertEqual(errors, [])
        self.assertEqual(len(files), 1)

    def test_duplicate_tags_fail_before_help_lookup(self):
        self.help("*test-api*\n")
        errors, _ = docs_checks.help_errors(self.root, "test")
        self.assertTrue(any("duplicate tag test-api" in issue for issue in errors))

    def test_broken_local_help_link_is_reported(self):
        self.help("See |test-missing|.\n")
        errors, _ = docs_checks.help_errors(self.root, "test")
        self.assertTrue(any("unresolved local help link test-missing" in issue for issue in errors))

    def test_missing_root_tag_is_reported(self):
        self.help()
        path = self.root / "doc/test.txt"
        path.write_text(path.read_text().replace("*test*\n", ""))
        errors, _ = docs_checks.help_errors(self.root, "test")
        self.assertIn("Missing help entry: test", errors)


if __name__ == "__main__":
    unittest.main()

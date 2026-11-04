"""Keep shipped templates, navigation targets and the C runtime in agreement."""
from html.parser import HTMLParser
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "ui"
RUNTIME = (ROOT / "src/htmlmain.c").read_text()
PAGES = sorted(UI.rglob("*.html"))


class Links(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.hrefs = []
        self.anchor_depth = 0
        self.nested_anchors = False
        self.feed(text)

    def handle_starttag(self, tag, attributes):
        if tag == "a":
            self.nested_anchors |= self.anchor_depth > 0
            self.anchor_depth += 1
            self.hrefs.extend(value for key, value in attributes if key == "href" and value)

    def handle_endtag(self, tag):
        if tag == "a":
            self.anchor_depth = max(0, self.anchor_depth - 1)


class UIContractTests(unittest.TestCase):
    def test_all_template_tokens_are_registered_by_runtime(self):
        registered = set(re.findall(r'\(struct kv\)\s*\{\s*"(\w+)"', RUNTIME))
        self.assertTrue(registered, "No runtime token registrations found")
        for page in PAGES:
            with self.subTest(page=str(page.relative_to(UI))):
                used = set(re.findall(r"\{\{(\w+)\}\}", page.read_text()))
                self.assertEqual(used - registered, set(), "Unimplemented template tokens")

    def test_static_navigation_targets_exist_inside_ui(self):
        for page in PAGES:
            for href in Links(page.read_text()).hrefs:
                match = re.fullmatch(r"act:(sub|func):(.+)", href)
                if not match:
                    continue
                kind, name = match.groups()
                with self.subTest(page=str(page.relative_to(UI)), href=href):
                    self.assertRegex(name, r"^[A-Za-z0-9_-]+\.html$")
                    directory = "subpages" if kind == "sub" else "functions"
                    self.assertTrue((UI / directory / name).is_file(), "Missing navigation page")

    def test_static_control_actions_have_a_runtime_handler(self):
        exact = set(re.findall(r'strcmp\(a,\s*"([^"]+)"\)', RUNTIME))
        prefixes = set(re.findall(r'strncmp\(a,\s*"([^"]+)",\s*\d+\)', RUNTIME))
        self.assertTrue(exact and prefixes, "No runtime action dispatch found")
        for page in PAGES:
            for href in Links(page.read_text()).hrefs:
                if not href.startswith("act:") or "{{" in href:
                    continue
                action = href[4:]
                with self.subTest(page=str(page.relative_to(UI)), action=action):
                    self.assertTrue(action in exact or any(action.startswith(p) for p in prefixes),
                                    "Page action has no runtime handler")

    def test_main_navigation_has_three_pages(self):
        top_level = sorted(p.name for p in UI.glob("*.html") if re.match(r"\d+-", p.name))
        self.assertEqual(top_level, ["00-overview.html", "01-signal.html", "02-functions.html"])
        for target in ["subpages/charts.html", "subpages/settings.html", "subpages/device.html"]:
            self.assertTrue((UI / target).is_file(), "Moved diagnostics/settings page is missing")

    def test_builtin_controller_helpers_are_shipped(self):
        self.assertTrue((UI / "functions/cpuctl.sh").is_file())
        self.assertIn('"/functions/cpuctl.sh"', RUNTIME)
        self.assertTrue((UI / "subpages/shellcrash-mode.sh").is_file())
        self.assertIn("{{TOAST}}", (UI / "subpages/wifi.html").read_text())

    def test_click_targets_do_not_nest_two_actions(self):
        for page in PAGES:
            with self.subTest(page=str(page.relative_to(UI))):
                self.assertFalse(Links(page.read_text()).nested_anchors)

    def test_wifi_password_is_supplied_by_the_masked_runtime_field(self):
        page = (UI / "subpages/wifi.html").read_text()
        self.assertRegex(page, r'id="wifi-key5">\s*\{\{KEY5_HTML\}\}')
        self.assertRegex(page, r'id="wifi-key24">\s*\{\{KEY24_HTML\}\}')
        self.assertIn('href="act:revealkey"', page)
        self.assertRegex(page, r">\s*\{\{KEYBTN\}\}\s*</a>")


if __name__ == "__main__":
    unittest.main()

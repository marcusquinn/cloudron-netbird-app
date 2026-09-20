#!/usr/bin/env python3
"""Offline checks for relocated operator documentation and AI entrypoints."""
from pathlib import Path
import re
import unittest
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
GUIDES = ('PACKAGING-NOTES', 'PUBLISHING', 'SSO-SWITCH', 'MULTI-INSTANCE',
          'INGRESS-HARDENING', 'REVERSE-PROXY')


class DocumentationTest(unittest.TestCase):
    def test_operator_guides_have_one_canonical_location(self):
        for name in GUIDES:
            with self.subTest(guide=name):
                self.assertTrue((ROOT / 'docs' / (name + '.md')).is_file())
                self.assertFalse((ROOT / (name + '.md')).exists())

    def test_relative_links_from_entrypoints_and_guides_resolve(self):
        paths = list((ROOT / 'docs').glob('*.md')) + [ROOT / p for p in (
            'README.md', 'AGENTS.md', 'SECURITY.md', 'DESIGN.md', '.agents/AGENTS.md')]
        for path in paths:
            for link in re.findall(r'\]\(([^\s)]+)\)', path.read_text()):
                target = urlsplit(link)
                if target.scheme or target.netloc or not target.path:
                    continue
                with self.subTest(source=path.relative_to(ROOT), link=link):
                    destination = (path.parent / unquote(target.path)).resolve()
                    self.assertTrue(destination.is_relative_to(ROOT))
                    self.assertTrue(destination.exists(), 'Missing relative link target')


if __name__ == '__main__':
    unittest.main()

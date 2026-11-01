#!/usr/bin/env python3
"""Check the hand-written documentation pages.

The three pages under docs/ are written by hand and only the API page is
generated, so the things that break silently are the ones a browser forgives: an
anchor that no longer exists, a link to a file that was renamed, a section that
was opened and never closed. This script fails on all three.

    python3 scripts/check_docs.py

It exits 0 when the pages are sound and 1 with a list of what is wrong.
"""

import html.parser
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGES = ["index.html", "guide.html", "api.html"]

# Tags whose balance is worth checking: the structural ones, where a missing
# close swallows whole sections rather than mis-styling one word.
PAIRED = {"div", "table", "tbody", "thead", "pre", "p", "ul", "li", "section"}
VOID = {"br", "img", "meta", "link", "input", "hr"}


class Collector(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.hrefs = []
        self.srcs = []
        self.stack = []
        self.unbalanced = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag == "a" and attrs.get("href"):
            self.hrefs.append(attrs["href"])
        if tag in ("img", "script", "link") and attrs.get("src"):
            self.srcs.append(attrs["src"])
        if tag in PAIRED:
            self.stack.append(tag)
        elif tag not in VOID:
            # A tag we do not track is fine, but it must not look like one we do.
            pass

    def handle_endtag(self, tag):
        if tag in PAIRED:
            if not self.stack:
                self.unbalanced.append("stray </%s>" % tag)
            elif self.stack[-1] != tag:
                self.unbalanced.append(
                    "</%s> closes <%s>" % (tag, self.stack[-1])
                )
                if tag in self.stack:
                    while self.stack and self.stack.pop() != tag:
                        pass
            else:
                self.stack.pop()


def check(page):
    path = os.path.join(ROOT, "docs", page)
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    collector = Collector()
    collector.feed(text)
    collector.close()

    problems = []
    for problem in collector.unbalanced:
        problems.append(problem)
    for tag in collector.stack:
        problems.append("<%s> is never closed" % tag)

    for href in collector.hrefs:
        if href.startswith("#"):
            target = href[1:]
            if target and target not in collector.ids:
                problems.append("href=\"%s\" points at no id" % href)
        elif href.startswith("http") or href.startswith("mailto:"):
            continue
        else:
            local = href.split("#")[0]
            if local and not os.path.exists(os.path.join(ROOT, "docs", local)):
                problems.append("href=\"%s\" points at no file" % href)

    for src in collector.srcs:
        if src.startswith("http"):
            continue
        if not os.path.exists(os.path.join(ROOT, "docs", src)):
            problems.append("src=\"%s\" points at no file" % src)

    # The same id twice makes a link land on whichever one the browser saw first.
    seen = {}
    for match in re.finditer(r'id="([^"]+)"', text):
        seen[match.group(1)] = seen.get(match.group(1), 0) + 1
    for name, count in seen.items():
        if count > 1:
            problems.append('id="%s" appears %d times' % (name, count))

    return problems


def main():
    failed = False
    for page in PAGES:
        path = os.path.join(ROOT, "docs", page)
        if not os.path.exists(path):
            print("%s: missing" % page)
            failed = True
            continue
        problems = check(page)
        if problems:
            failed = True
            for problem in problems:
                print("%s: %s" % (page, problem))
        else:
            print("%s: ok" % page)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Keeps the exported attachments of a failed UI test only when its failure was on a screen
that shows no words.

CI runs `xcresulttool export attachments --only-failures` into a folder that becomes part of a
downloadable artifact. Screenshots of the screens that show or take recovery words must not be
in it (test phones included), and not every one of those screens draws its words in the secure
layer. So a failed test's attachments stay only if every failure message carries the UI tree
that `see()` and `tap()` print (`app.debugDescription`, first 4000 characters), the tree was not
cut, and it holds no word screen. Everything else is deleted. Fails closed: anything that cannot
be read is deleted.

Run: failure-attachments.py <ui.xcresult> <exported folder>
"""
import json
import os
import re
import shutil
import subprocess
import sys

# Word rows, card-check choices, typed-word fields and the word keypad, and the titles of those screens.
WORD_SCREEN = re.compile(
    r"identifier: '(?:word-\d|choice |field-\d|key )|Which is word|Words \d+ to \d+|Type your 24 words|Show my words"
)
TREE = "Element subtree:"
TREE_LIMIT = 4000  # SealctlTestCase prints app.debugDescription.prefix(4000)


def failed_tests(xcresult):
    """nodeIdentifier -> failure messages, for every failed test case."""
    out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", xcresult],
                         capture_output=True, text=True, check=True).stdout
    found = {}

    def walk(node):
        if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
            found[node.get("nodeIdentifier", "")] = [
                c.get("name", "") for c in node.get("children", []) if c.get("nodeType") == "Failure Message"]
        for c in node.get("children", []):
            walk(c)

    for n in json.loads(out).get("testNodes", []):
        walk(n)
    return found


def no_words_shown(messages):
    if not messages:
        return False
    for m in messages:
        if TREE not in m:
            return False
        tree = m.split("\n", 1)[1] if "\n" in m else ""
        if len(tree) >= TREE_LIMIT or WORD_SCREEN.search(tree):
            return False
    return True


def main(xcresult, folder):
    try:
        failed = failed_tests(xcresult)
        with open(os.path.join(folder, "manifest.json")) as f:
            manifest = json.load(f)
    except Exception as e:  # noqa: BLE001 - fail closed
        print(f"cannot read the results ({type(e).__name__}): every attachment withheld")
        manifest, failed = [], {}
    keep = {t for t, msgs in failed.items() if no_words_shown(msgs)}
    kept_entries, kept_files = [], set()
    for entry in manifest if isinstance(manifest, list) else []:
        test = entry.get("testIdentifier", "")
        if test in keep:
            kept_entries.append(entry)
            kept_files.update(a.get("exportedFileName", "") for a in entry.get("attachments", []))
            print(f"kept: {test}")
        else:
            print(f"withheld (a words screen, or the screen is unknown): {test}")
    for name in os.listdir(folder):
        if name not in kept_files:
            path = os.path.join(folder, name)
            shutil.rmtree(path) if os.path.isdir(path) and not os.path.islink(path) else os.remove(path)
    with open(os.path.join(folder, "manifest.json"), "w") as f:
        json.dump(kept_entries, f, indent=1)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

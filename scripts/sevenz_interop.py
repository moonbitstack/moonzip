#!/usr/bin/env python3
"""Hand 7z archives to 7-Zip itself, and take its word for what they contain.

    python3 scripts/sevenz_interop.py [--seven-zip PATH]

The archives are the ones `src/examples/vectors` writes with the streaming
writer: two members, one of them the sample body for its kind, so the extraction
can be compared byte for byte rather than by size.

This is one direction only, and on purpose. The other -- 7-Zip writes, we read --
is a test rather than a script: `src/sevenz/interop_test.mbt` pins archives 7-Zip
wrote, and `src/sevenz/stream_test.mbt` feeds them through the streaming reader in
pieces. CI runs those; CI has no 7-Zip, and this script is for a machine that
does.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

from conformance import sample

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECOND = b"the second member"


def find_seven_zip(explicit):
    """The 7-Zip binary: what was named, then what is on the path."""
    if explicit:
        return explicit
    for name in ("7zz", "7z", "7za"):
        found = shutil.which(name)
        if found:
            return found
    raise SystemExit("no 7-Zip binary found; pass --seven-zip")


def run(command):
    done = subprocess.run(command, capture_output=True)
    if done.returncode != 0:
        raise SystemExit(
            "{} failed:\n{}{}".format(
                " ".join(command),
                done.stdout.decode(errors="replace"),
                done.stderr.decode(errors="replace"),
            )
        )
    return done.stdout


def our_archives(vectors):
    """Every 7z archive the vectors example prints, by kind."""
    if vectors:
        with open(vectors, encoding="utf-8") as handle:
            out = handle.read()
    else:
        out = subprocess.run(
            ["moon", "run", "src/examples/vectors", "--target", "native"],
            cwd=ROOT,
            capture_output=True,
            check=True,
        ).stdout.decode()
    archives = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0] == "sevenz":
            archives[int(parts[1])] = bytes.fromhex(parts[2])
    return archives


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seven-zip", default=None)
    parser.add_argument(
        "--vectors",
        default=None,
        help="a saved `moon run src/examples/vectors` transcript",
    )
    options = parser.parse_args()
    seven_zip = find_seven_zip(options.seven_zip)
    archives = our_archives(options.vectors)
    if not archives:
        raise SystemExit("the vectors example printed no 7z archives")
    checked = 0
    with tempfile.TemporaryDirectory() as workdir:
        for kind, blob in sorted(archives.items()):
            name = os.path.join(workdir, "ours-{}.7z".format(kind))
            with open(name, "wb") as out:
                out.write(blob)
            target = os.path.join(workdir, "out-{}".format(kind))
            run([seven_zip, "x", "-y", "-o" + target, name])
            # An empty member is not a file every extractor creates.
            body = sample(kind)
            first_at = os.path.join(target, "first.txt")
            first = open(first_at, "rb").read() if os.path.exists(first_at) else b""
            if first != body:
                raise SystemExit(
                    "kind {}: first.txt is {} bytes, not {}".format(
                        kind, len(first), len(body)
                    )
                )
            second = open(os.path.join(target, "dir", "second.txt"), "rb").read()
            if second != SECOND:
                raise SystemExit("kind {}: the second member is wrong".format(kind))
            checked += 1
    print("sevenz: {} archives written here extracted by 7-Zip".format(checked))
    return 0


if __name__ == "__main__":
    sys.exit(main())

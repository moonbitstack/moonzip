#!/usr/bin/env python3
"""Read and write ZIP archives with 7-Zip itself, in both directions.

    python3 scripts/sevenzip_interop.py [--seven-zip PATH]

`scripts/conformance.py` hands our archives to Python's `zipfile`, which cannot
read WinZip AES and does not do volumes. 7-Zip can do both, so this script is the
one that says an encrypted archive written here opens somewhere else, and that an
archive written by another tool opens here.

Two directions, and they are checked differently:

* ours to 7-Zip -- 7-Zip extracts each archive we write, and the extraction is
  compared byte for byte. This half cannot be pinned, because our encoder is
  allowed to improve and its bytes are allowed to change.
* 7-Zip to ours -- the archives 7-Zip writes are pinned into
  `src/zip/sevenzip_test.mbt`, which the test suite replays. CI runs the test,
  not this script, so CI needs no 7-Zip.

The password is `moonzip` throughout, and the members are small on purpose: an
archive that a reader can hold in a test is worth more than one that shows off a
key length.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

from conformance import sample

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# What the vectors example puts in its archives, and what this script asks 7-Zip
# to put in the ones it writes. The names differ because the example's members
# are the sample bodies and these are two fixed sentences.
MEMBERS = [("first.txt", None), ("dir/second.txt", b"the second member")]
REFERENCE = [("one.txt", b"the first member"), ("two/three.txt", b"the second member")]
PASSWORD = "moonzip"


def find_seven_zip(explicit):
    """The 7-Zip binary: what was named, then what is on the path."""
    if explicit:
        return explicit
    for name in ("7zz", "7z", "7za"):
        found = shutil.which(name)
        if found:
            return found
    raise SystemExit("no 7-Zip binary found; pass --seven-zip")


def run(command, **kwargs):
    done = subprocess.run(command, capture_output=True, **kwargs)
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
    """Every archive our writer produces, as the vectors example prints them."""
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
    sets = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[0] == "zip":
            archives[(int(parts[1]), int(parts[2]))] = bytes.fromhex(parts[3])
        if len(parts) > 3 and parts[0] == "zipvol":
            sets[(int(parts[1]), parts[2])] = [bytes.fromhex(p) for p in parts[3:]]
    return archives, sets


def check_ours_with_seven_zip(seven_zip, workdir, vectors):
    """7-Zip extracts what we write, for every shape that carries encryption."""
    archives, sets = our_archives(vectors)
    checked = 0
    for (kind, variant), blob in sorted(archives.items()):
        if variant < 5:
            # The plain shapes are Python's to check; these six are the ones it
            # cannot open.
            continue
        name = os.path.join(workdir, "ours-{}-{}.zip".format(kind, variant))
        with open(name, "wb") as out:
            out.write(blob)
        target = os.path.join(workdir, "out-{}-{}".format(kind, variant))
        run(
            [
                seven_zip,
                "x",
                "-y",
                "-p" + PASSWORD,
                "-o" + target,
                name,
            ]
        )
        first_at = os.path.join(target, "first.txt")
        # An empty member is not a file every extractor creates, and the vectors
        # example writes one for its empty input.
        first = open(first_at, "rb").read() if os.path.exists(first_at) else b""
        second = open(os.path.join(target, "dir", "second.txt"), "rb").read()
        if second != MEMBERS[1][1]:
            raise SystemExit(
                "kind {} variant {}: the second member is wrong".format(kind, variant)
            )
        if first != sample(kind):
            raise SystemExit(
                "kind {} variant {}: the first member is wrong".format(kind, variant)
            )
        checked += 1
    # Volumes: 7-Zip reads a set of `.001`, `.002`, ... pieces as one archive, so
    # each of our sets is written under those names and extracted whole.
    for (kind, shape), pieces in sorted(sets.items()):
        base = os.path.join(workdir, "ours-{}-{}".format(kind, shape))
        for index, piece in enumerate(pieces, start=1):
            with open("{}.{:03d}".format(base, index), "wb") as out:
                out.write(piece)
        target = base + "-out"
        run([seven_zip, "x", "-y", "-pmoonzip", "-o" + target, base + ".001"])
        second = open(os.path.join(target, "dir", "second.txt"), "rb").read()
        if second != MEMBERS[1][1]:
            raise SystemExit(
                "kind {} {}: a volume's second member is wrong".format(kind, shape)
            )
        checked += 1
    return checked


def seven_zip_archives(seven_zip, workdir):
    """The archives 7-Zip writes: plain, encrypted, and in volumes."""
    source = os.path.join(workdir, "src")
    os.makedirs(os.path.join(source, "two"), exist_ok=True)
    for name, body in REFERENCE:
        meta = os.path.join(source, name)
        os.makedirs(os.path.dirname(meta), exist_ok=True)
        with open(meta, "wb") as out:
            out.write(body)
    made = {}
    for name, flags in [
        ("plain", []),
        ("aes128", ["-p" + PASSWORD, "-mem=AES128"]),
        ("aes256", ["-p" + PASSWORD, "-mem=AES256"]),
    ]:
        path = os.path.join(workdir, name + ".zip")
        run([seven_zip, "a", "-tzip", path, "one.txt", "two", "-r"] + flags, cwd=source)
        made[name] = (open(path, "rb").read(), PASSWORD if flags else None)
    # Volumes: 7-Zip writes `vol.zip.001`, `vol.zip.002`, ... in one-kilobyte
    # pieces, which is the shape a caller feeds to `unzip_split` after reading
    # the files in name order.
    path = os.path.join(workdir, "vol.zip")
    run(
        [seven_zip, "a", "-tzip", path, "-v1k", "-p" + PASSWORD, "-mem=AES256", "one.txt", "two", "-r"],
        cwd=source,
    )
    pieces = []
    index = 1
    while True:
        piece = "{}.{:03d}".format(path, index)
        if not os.path.exists(piece):
            break
        pieces.append(open(piece, "rb").read())
        index += 1
    made["volume"] = (pieces, PASSWORD)
    return made


def write_vectors(made):
    """Pin what 7-Zip wrote, so the test suite can replay it without 7-Zip."""
    lines = []
    lines.append("// Copyright 2026 Leo Cheng")
    lines.append("// SPDX-License-Identifier: Apache-2.0")
    lines.append("")
    lines.append("///|")
    lines.append("/// Archives written by 7-Zip itself, pinned as they came out.")
    lines.append("///")
    lines.append("///     python3 scripts/sevenzip_interop.py")
    lines.append("///")
    lines.append("/// regenerates this file. Python's `zipfile` cannot write WinZip AES and")
    lines.append("/// does not do volumes, so `scripts/interop.py` cannot produce these;")
    lines.append("/// 7-Zip can, and an archive written by a different tool is the only")
    lines.append("/// evidence that a reader was not written against its own output.")
    lines.append("")
    lines.append("///|")
    lines.append("fn seven_zip(name : String) -> Bytes {")
    first = True
    for name in ("plain", "aes128", "aes256", "volume"):
        blob = made[name][0]
        if isinstance(blob, list):
            continue
        keyword = "if" if first else "if"
        first = False
        lines.append('  {} name == "{}" {{'.format(keyword, name))
        lines.append("    return @base16.decode_lossy(")
        lines.append('      "{}",'.format(blob.hex()))
        lines.append("    )")
        lines.append("  }")
    lines.append('  abort("no pinned archive named \\{name}")')
    lines.append("}")
    lines.append("")
    lines.append("///|")
    lines.append("/// The volume set 7-Zip wrote, in the order its names put them.")
    lines.append("fn seven_zip_volumes() -> Array[Bytes] {")
    lines.append("  [")
    for piece in made["volume"][0]:
        lines.append("    @base16.decode_lossy(")
        lines.append('      "{}",'.format(piece.hex()))
        lines.append("    ),")
    lines.append("  ]")
    lines.append("}")
    lines.append("")
    lines.append("///|")
    lines.append("/// What every one of those archives holds. 7-Zip records the directory")
    lines.append("/// `two/` as a member of its own, so the members are looked up by name")
    lines.append("/// rather than counted: a reader that dropped one would still see three.")
    lines.append("fn seven_zip_check(archive : Bytes, password : String?) -> Unit raise {")
    lines.append("  let members = match password {")
    lines.append("    Some(secret) => @zip.unzip(archive[:], password=secret)")
    lines.append("    None => @zip.unzip(archive[:])")
    lines.append("  }")
    lines.append("  let mut found = 0")
    lines.append("  for entry in members {")
    lines.append("    match entry.name {")
    lines.append('      "one.txt" => {')
    lines.append('        assert_eq(entry.data, b"the first member")')
    lines.append("        found += 1")
    lines.append("      }")
    lines.append('      "two/three.txt" => {')
    lines.append('        assert_eq(entry.data, b"the second member")')
    lines.append("        found += 1")
    lines.append("      }")
    lines.append("      _ => ()")
    lines.append("    }")
    lines.append("  }")
    lines.append("  assert_eq(found, 2)")
    lines.append("}")
    lines.append("")
    lines.append("///|")
    lines.append("test {")
    lines.append('  seven_zip_check(seven_zip("plain"), None)')
    lines.append('  seven_zip_check(seven_zip("aes128"), Some("moonzip"))')
    lines.append('  seven_zip_check(seven_zip("aes256"), Some("moonzip"))')
    lines.append("  // The volume set, joined in the order 7-Zip's names put it in.")
    lines.append("  seven_zip_check(")
    lines.append("    @zip.join(seven_zip_volumes()),")
    lines.append('    Some("moonzip"),')
    lines.append("  )")
    lines.append("}")
    path = os.path.join(ROOT, "src", "zip", "sevenzip_test.mbt")
    with open(path, "w", encoding="utf-8", newline="\n") as out:
        out.write("\n".join(lines) + "\n")
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seven-zip", default=None)
    parser.add_argument(
        "--vectors",
        default=None,
        help="a saved `moon run src/examples/vectors` dump, for a machine that "
        "has 7-Zip but not the toolchain",
    )
    args = parser.parse_args()
    seven_zip = find_seven_zip(args.seven_zip)
    workdir = tempfile.mkdtemp(prefix="moonzip-7z-")
    try:
        checked = check_ours_with_seven_zip(seven_zip, workdir, args.vectors)
        print("7-Zip read {} archives we wrote".format(checked))
        made = seven_zip_archives(seven_zip, workdir)
        path = write_vectors(made)
        print("pinned {} archives into {}".format(len(made), os.path.relpath(path, ROOT)))
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

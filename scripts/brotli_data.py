#!/usr/bin/env python3
"""Generate `brotli/data.mbt` from the reference sources.

Three tables live in the brotli reference distribution and none of them can be
derived at run time: the static dictionary (122,784 bytes of common words), the
121 word transforms and their 49 prefix/suffix fragments, and the 2,048-entry
literal context lookup table. They are transcribed here, byte for byte, so the
decoder agrees with every other brotli implementation on earth.

Usage:  python scripts/brotli_data.py .temp-ref/brotli
"""

import os
import re
import sys

# The transform table names its types by enum rather than by number.
TRANSFORM_NAMES = {"BROTLI_TRANSFORM_IDENTITY": 0}
for _i in range(1, 10):
    TRANSFORM_NAMES["BROTLI_TRANSFORM_OMIT_LAST_%d" % _i] = _i
TRANSFORM_NAMES["BROTLI_TRANSFORM_UPPERCASE_FIRST"] = 10
TRANSFORM_NAMES["BROTLI_TRANSFORM_UPPERCASE_ALL"] = 11
for _i in range(1, 10):
    TRANSFORM_NAMES["BROTLI_TRANSFORM_OMIT_FIRST_%d" % _i] = 11 + _i
TRANSFORM_NAMES["BROTLI_TRANSFORM_SHIFT_FIRST"] = 21
TRANSFORM_NAMES["BROTLI_TRANSFORM_SHIFT_ALL"] = 22


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def c_string(src, name):
    """Parse `char name[...] = "..." "...";` into a list of ints."""
    start = src.index(name)
    eq = src.index("=", start)
    semi = src.index(";", eq)
    body = src[eq + 1 : semi]
    out = []
    for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', body):
        i = 0
        while i < len(literal):
            ch = literal[i]
            if ch != "\\":
                out.extend(ch.encode("utf-8"))
                i += 1
                continue
            i += 1
            esc = literal[i]
            if esc == "x":
                out.append(int(literal[i + 1 : i + 3], 16))
                i += 3
            elif esc in "01234567":
                j = i
                while j < len(literal) and j < i + 3 and literal[j] in "01234567":
                    j += 1
                out.append(int(literal[i:j], 8))
                i = j
            elif esc == "n":
                out.append(10)
                i += 1
            elif esc == "t":
                out.append(9)
                i += 1
            elif esc == "r":
                out.append(13)
                i += 1
            else:
                out.append(ord(esc))
                i += 1
    return out


def c_ints(src, name):
    """Parse `type name[...] = { 1, 2, 3 };` into a list of ints."""
    start = src.index(name)
    eq = src.index("=", start)
    brace = src.index("{", eq)
    depth = 0
    body = ""
    for i in range(brace, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                body = src[brace + 1 : i]
                break
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
    body = re.sub(r"//[^\n]*", "", body)
    return [
        TRANSFORM_NAMES[tok] if tok in TRANSFORM_NAMES else int(tok, 0)
        for tok in re.findall(r"0x[0-9a-fA-F]+|\d+|[A-Z_][A-Z0-9_]+", body)
    ]


def emit_bytes(name, data, doc):
    """One literal per 8 KiB, joined once into the finished blob.

    A single literal is not an option: the compiler refuses a token longer than
    65,535 characters and the dictionary needs half a million. Concatenating the
    literals with `+` is not an option either, because that reallocates and copies
    everything once per part. Parts plus one preallocated join is both.
    """
    parts = [data[i : i + 8192] for i in range(0, len(data), 8192)]
    out = ["///|", "/// " + doc, "let %s_parts : FixedArray[Bytes] = [" % name]
    for part in parts:
        out.append('  b"%s",' % "".join("\\x%02x" % b for b in part))
    out.append("]")
    out.append("")
    out.append("///|")
    out.append("let %s : Bytes = join(%s_parts)" % (name, name))
    return "\n".join(out) + "\n"


def emit_ints(name, data, doc, width=12):
    out = ["///|", "/// " + doc, "let %s : FixedArray[Int] = [" % name]
    for i in range(0, len(data), width):
        out.append("  " + ", ".join(str(v) for v in data[i : i + width]) + ",")
    out.append("]")
    return "\n".join(out) + "\n"


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else ".temp-ref/brotli"
    common = os.path.join(root, "c", "common")

    with open(os.path.join(common, "dictionary.bin"), "rb") as f:
        dictionary = list(f.read())
    transforms_src = read(os.path.join(common, "transform.c"))
    context_src = read(os.path.join(common, "context.c"))

    # The C array is declared 217 bytes and initialised from a 216-byte string;
    # the last byte is the implicit terminator, which the final prefix-suffix id
    # reaches and which means "no fragment".
    prefix_suffix = c_string(transforms_src, "kPrefixSuffix[217]") + [0]
    prefix_suffix_map = c_ints(transforms_src, "kPrefixSuffixMap[50]")
    transforms = c_ints(transforms_src, "kTransformsData[]")
    context_lut = c_ints(context_src, "_kBrotliContextLookupTable[2048]")

    assert len(dictionary) == 122784, len(dictionary)
    assert len(prefix_suffix) == 217, len(prefix_suffix)
    assert len(prefix_suffix_map) == 50, len(prefix_suffix_map)
    assert len(transforms) == 121 * 3, len(transforms)
    assert len(context_lut) == 2048, len(context_lut)

    header = '''///|
/// Transcribed from the brotli reference distribution (MIT). Regenerate with
/// `python scripts/brotli_data.py .temp-ref/brotli`; never edit by hand.
///
/// Three tables, none derivable at run time:
///
/// * `dictionary` — the 122,784-byte static dictionary: 13,504 words laid out
///   in 25 length buckets. A backward reference past the window is an index into
///   this blob, so a decoder without it reads real files correctly up to the
///   first common English word and then silently corrupts.
/// * `prefix_suffix` — the 49 fragments the word transforms glue on, as
///   length-prefixed byte strings.
/// * `transforms` — 121 triples of (prefix id, transform id, suffix id).
/// * `context_lut` — the literal context table, four 512-entry quadrants, one
///   per context mode.
///
/// The bytes arrive in parts because a MoonBit token cannot exceed 65,535
/// characters; `join` stitches them once, at start-up.

///|
fn join(parts : FixedArray[Bytes]) -> Bytes {
  let mut size = 0
  for part in parts {
    size += part.length()
  }
  let out = FixedArray::make(size, b'\\x00')
  let mut at = 0
  for part in parts {
    for i in 0..<part.length() {
      out[at] = part[i]
      at += 1
    }
  }
  Bytes::from_array(out)
}

'''

    body = [
        emit_bytes("dictionary", dictionary, "The static dictionary, 122,784 bytes, 13,504 words."),
        emit_bytes("prefix_suffix", prefix_suffix, "The 49 transform fragments, length-prefixed."),
        emit_ints("prefix_suffix_map", prefix_suffix_map, "Offset of each fragment in `prefix_suffix`."),
        emit_ints("transforms", transforms, "121 transforms: prefix id, transform id, suffix id."),
        emit_ints("context_lut", context_lut, "Literal context lookup, four quadrants of 512 entries.", width=16),
    ]

    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src", "brotli", "data.mbt")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(header + "\n".join(body))
    print("wrote %s (%d bytes of dictionary, %d transforms)" % (path, len(dictionary), len(transforms) // 3))


if __name__ == "__main__":
    main()

# moonzip

Compression for MoonBit: DEFLATE, and the two containers built on it.

```moonbit
let small = @gzip.gzip(body[:])
let back = @gzip.gunzip(small[:])    // raises if the checksum disagrees

// The raw stream, for a protocol that carries its own framing.
@deflate.deflate(body[:])
@deflate.inflate(stream[:])
```

Run `moon run examples/tour` for the whole surface in one go.

## Packages

| Package | What | Specification |
|:--:|:--|:--|
| `deflate` | DEFLATE, both directions | RFC 1951 |
| `gzip` | The gzip container, with CRC-32 | RFC 1952 |
| `zlib` | The zlib container, with Adler-32 | RFC 1950 |

## What it reads and what it writes

The reader takes **all three block types**, including the dynamic Huffman blocks
that zlib, gzip and every browser actually emit. A reader without those reads
almost nothing in practice, which is why it is not a later step.

The writer emits one fixed-Huffman block with LZ77 back-references over a 32 KiB
window. A dynamic block must carry its own code tables, which costs more than it
saves on the short bodies a response compressor sees. The output is ordinary
DEFLATE, so anything else reads it.

gzip writes a zero modification time and no file name, so the same input always
gives the same bytes — a compressor that stamped the clock would make a build
unreproducible and a cache entry never match.

Both containers **check their checksum and their length** on the way back. A
container that carries a checksum and does not look at it is not a container.

## What is checked

Every stream this library's compressor produces was handed to zlib, which got
the input back; those exact streams are the vectors in the test. The other
direction too: zlib compresses the same seven inputs at four levels, and those
streams — dynamic Huffman, which this compressor never emits — must decompress
to the input. Then the checksums against zlib's own, and a set of broken streams
that must be refused: a flipped payload byte, a truncation, a bad header, a
back-reference reaching before the start of the output.

The seven inputs run from nothing to seventy kilobytes, past the 32 KiB window.

## What is not here yet

Brotli, Zstandard, LZ4 and Snappy; streaming, which would let a body be
compressed without being held; and a dynamic-Huffman writer. They are planned in
that order; the tracking list lives with the project.

CRC-32 and Adler-32 live with the containers that specify them. When the
checksum package in `mooncrypt` lands they will move there and be re-exported.

## Install

```bash
moon add moonbitstack/moonzip
```

## Licence

Apache-2.0.

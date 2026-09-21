# moonzip

Compression for MoonBit: DEFLATE, the two stream containers built on it, and the ZIP archive.

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
| `zip` | The ZIP archive: read, write, list, and one member at a time | APPNOTE.TXT |

## Configuration

Every bound the encoder and the decoder have is an argument, and every default
is the one the mainstream uses.

```moonbit
@deflate.deflate(body[:])                    // level 6, a 32 KiB window
@deflate.deflate(body[:], level=9)           // search hardest
@deflate.deflate(body[:], level=0)           // store, do not compress
@deflate.deflate(body[:], chain=2048)        // set the search depth directly

@deflate.inflate(stream[:], limit=1 << 20)   // refuse to expand past a megabyte

@gzip.gzip(body[:], name="report.csv", mtime=written_at)
@gzip.gunzip(stream[:], checksum=false)      // read what a damaged stream holds
```

| Setting | Default | Why that one |
|:--:|:--:|:--|
| `level` | 6 | zlib's default, and Go's, Python's and Node's. It maps to the same search depths zlib's own table uses, so a level here means what it means there |
| `window` | 32768 | The most DEFLATE allows, and the only size a reader can be assumed to handle |
| `chain` | from `level` | For a caller who would rather set the depth than pick a level |
| `limit` | unbounded | What every library does. A reader handling input from elsewhere should set it: a compressed stream says nothing about how far it expands |
| `mtime` | 0 | So the same input gives the same bytes. Go's `gzip.Writer` also writes zero unless told otherwise; a compressor that stamped the clock would make a build unreproducible |
| `checksum`, `length`, `header_crc` | on | A container that carries a checksum and does not look at it is not a container. Off is for reading what a damaged stream still holds |

`level=0` writes stored blocks, which is what "no compression" means everywhere.
`level=7` is the search depth this library used before the level existed, so
output written by 0.1.0 is still exactly reproducible — a test asserts it.

## Archives

`gzip` compresses one thing; `zip` holds many.

```moonbit
let archive = @zip.zip([
  @zip.Entry::new("hello.txt", b"hello"),
  @zip.Entry::new("dir/nested.txt", body, mtime=written_at),
][:])

@zip.names(archive[:])              // list it, without expanding anything
@zip.entry(archive[:], "hello.txt") // one member, expanding only that one
@zip.unzip(archive[:], limit=limit) // all of them, bounded
```

Listing does not expand: the central directory is a table at the end of the
archive naming every member, so `names` reads that and stops. This is what
`zipfile.namelist()` is, and the reason to have it.

A member is never made bigger by being compressed — an entry that deflates to no
less than it started as is stored instead, which is what `zip` itself does.

**Interoperability is the acceptance criterion, and it is checked both ways.**
An archive written here opens in Python's `zipfile` with `testzip()` reporting
every CRC correct, and an archive Python writes reads back here with the right
contents, methods and times. That check caught something a round-trip could not:
a systematic error in the MS-DOS date arithmetic would be invisible to a test
that writes and reads with the same code.

**Not yet**: Zip64 (archives past 4 GiB or 65535 members), encryption, split
volumes, and the data-descriptor form. They are the variants; the tracking list
has them.

**A method this package does not implement** — bzip2 is 12, LZMA is 14 — is a
`Codec` away rather than an edit here:

```moonbit
@zip.unzip(archive[:], codecs=mine[:])
```

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

Brotli, Zstandard, LZ4, Snappy, xz and tar; streaming, which would let a body
be compressed without being held; and a dynamic-Huffman writer.

Each format is one package here rather than a repository of its own, because a
subpackage already isolates what a caller carries: importing `moonzip/gzip` does
not bring `zstd` with it. There is no umbrella package re-exporting them all —
that would undo exactly what the split achieves, and `pub using` cannot carry an
enum's constructors through anyway.

CRC-32 lives at the root, because two containers specify it — `gzip` in its
trailer, `zip` in every entry — and neither should import the other to reach it.
Adler-32 stays with `zlib`, which is the only thing that uses it. When the
checksum package in `mooncrypt` lands they move there and are re-exported.

## Install

```bash
moon add moonbitstack/moonzip
```

## Licence

Apache-2.0.

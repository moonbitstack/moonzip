# moonzip

Compression for MoonBit. Eight formats, one per package, each with the interface
its own specification argues for — and no dependency beyond `moonbase`.

```moonbit
let small = @gzip.gzip(body[:])
let back = @gzip.gunzip(small[:])     // raises if the checksum disagrees

let archive = @zip.zip([@zip.Entry::new("readme.txt", body)][:])
let members = @zip.unzip(archive[:])
```

| Package | What | Specification |
|:--:|:--|:--|
| `deflate` | DEFLATE, both directions, all three block types | RFC 1951 |
| `gzip` | The gzip container, with CRC-32 | RFC 1952 |
| `zlib` | The zlib container, with Adler-32 | RFC 1950 |
| `zip` | The ZIP archive, with Zip64, descriptors and ZipCrypto | APPNOTE 6.3 |
| `tar` | ustar and pax, and `.tar.gz` on top | POSIX pax |
| `lz4` | The block and frame formats, with xxHash-32 | lz4 block, frame |
| `snappy` | The block and framing formats, with CRC-32C | Snappy |
| `lzma` | The LZMA codec and the `.lzma` container | LZMA SDK |

Run `moon run examples/tour` for the surface in one go, `examples/stream` for the
streaming pair, and `examples/archive` for the two containers.

Four more are on the way and are named here rather than discovered later:
**xz** and **7z** (both riding on the LZMA codec that is already here, blocked on
the LZMA2 chunk layer), **bzip2**, and **brotli**.
Nothing in this library is a stub that returns its input; a format is either
implemented or it is refused by name.

## Configuration

Every bound the encoder and the decoder have is an argument, and every default is
the one the mainstream uses.

```moonbit
@deflate.deflate(body[:])                    // level 6, a 32 KiB window
@deflate.deflate(body[:], level=9)           // search hardest
@deflate.deflate(body[:], level=0)           // store, do not compress
@deflate.deflate(body[:], blocks=Fixed)      // pin the block type
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
| `blocks` | `Auto` | The writer measures a dynamic candidate, a fixed one and a stored one per block and keeps the smallest — which is what zlib does |
| `limit` | unbounded | What every library does. A reader handling input from elsewhere should set it: a compressed stream says nothing about how far it expands |
| `mtime` | 0 | So the same input gives the same bytes. A compressor that stamped the clock would make a build unreproducible |
| `checksum`, `length`, `header_crc` | on | A container that carries a checksum and does not look at it is not a container. Off is for reading what a damaged stream still holds |

`level=0` writes stored blocks, which is what "no compression" means everywhere;
`blocks=Stored` says the same thing without going through a level. `level=7` is
the search depth this library used before the level existed, so output written by
0.1.0 is still exactly reproducible — a test asserts it.

## Streaming

A response body arrives in chunks. A file is read four kilobytes at a time.
Neither has to be gathered first.

```moonbit
// out
let writer = @gzip.Writer::new(level=9)
for part in parts {
  for b in writer.push(part) { out.push(b) }   // maybe nothing, at first
}
for b in writer.finish() { out.push(b) }       // the rest, plus the trailer

// back
let reader = @gzip.Reader::new()
for part in chunks {
  for b in reader.push(part) { out.push(b) }   // may cross a symbol
}
for b in reader.finish() { out.push(b) }       // and the trailer is checked here
```

The only state carried between calls is the 32 KiB window a back-reference can
reach, plus four bytes of running checksum — on both sides. `deflate`, `gzip` and
`zlib` have the pair; `zip` has a writer that hands back each member's bytes as it
adds them and a reader that walks local headers from the front, which is the only
way to read an archive that is still arriving.

A chunk boundary may fall inside a header field, inside a Huffman code, inside a
stored block, or between a member's data and its data descriptor. The tests feed
the same body in pieces of one, two, three, five, seven, thirteen, sixty-four,
five hundred and eleven, four thousand and ninety-six, and sixty-five thousand
five hundred and thirty-six bytes, and require the same bytes out each time. The
boundaries that break a naive decoder are never the round ones.

## Archives

`gzip` compresses one thing; `zip` and `tar` hold many.

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

`zip` writes and reads the variants a real archive carries:

```moonbit
@zip.zip(entries[:], zip64=true)          // sixty-four-bit sizes and offsets
@zip.zip(entries[:], descriptor=true)     // sizes after each member, not before
@zip.zip(entries[:], password="hunter2")  // ZipCrypto
@zip.unzip(archive[:], password="hunter2")
```

Zip64 turns itself on when an entry or an offset does not fit in thirty-two bits,
because that is the only reason it exists; forcing it is for a caller whose reader
expects the wide form. A data descriptor is what a writer that has not finished
reading a member must use — it cannot know the sizes when it writes the header.

`tar` is the other half of the same idea, with no compressed members: one header
per file, the bytes, and two empty blocks at the end. A `.tar.gz` compresses the
whole archive rather than each member, which is why it beats the same files
compressed one at a time.

```moonbit
@tar.tar([@tar.Entry::new("a.txt", body), @tar.Entry::directory("empty")][:])
@tar.targz(files[:])        // and untargz
```

Long names go in a pax extended header; a path that can be split between the name
and prefix fields stays in the ustar header, which is what readers from before
2001 can read. Symbolic links, directories, permission bits, owners and base-256
numbers all round-trip.

**On encryption**: ZipCrypto is the cipher the format called encryption for
fifteen years, and it is broken — a known-plaintext attack recovers the keys from
a dozen bytes. It is here because archives in the wild still carry it, and opening
one should not need a second tool. It is not a security boundary, and nothing in
this library will claim it is. AES is the gap; it is named here rather than
discovered later.

**A method this package does not implement** — bzip2 is 12, LZMA is 14 — is a
`Codec` away rather than an edit here:

```moonbit
@zip.unzip(archive[:], codecs=mine[:])
```

## LZMA

A range coder with a binary-probability model: no bit stream to align, one table
of probabilities updated per decision, and a matched-literal trick that makes the
byte after a match much cheaper than a byte after a literal.

```moonbit
@lzma.lzma(body[:])            // the .lzma alone container
@lzma.unlzma(packed[:])        // both a stated length and an end marker
```

Levels 0–9 map to the same dictionary sizes `xz` uses. The encoder is a greedy
hash-chain parse, which is roughly zlib's level six in effort — a stream real
decoders read, not the last few percent.

This is the codec that xz and 7z are built on, which is why it is a package of its
own: the container work comes next, and it will not need a second codec.

## The formats chosen for speed

`lz4` and `snappy` trade ratio for decode speed, and the numbers below are what
the trade costs on the same body — 184,000 bytes of English text with a periodic
tail, printed by `examples/stream`.

| Format | Bytes | Of the original |
|:--|--:|--:|
| gzip | 1,983 | 1.1% |
| lz4 block | 1,997 | 1.1% |
| lz4 frame (three 64 KiB blocks) | 4,576 | 2.5% |
| deflate, dynamic blocks | 2,661 | 1.4% |
| zlib | 2,667 | 1.4% |
| snappy block | 9,884 | 5.4% |
| snappy frame (three 64 KiB chunks) | 12,439 | 6.8% |
| — nothing | 184,000 | 100% |

That lz4 beats DEFLATE here is the body's fault: four thousand repetitions of one
sentence are exactly what a two-byte back-reference is for. On prose, DEFLATE
wins, because Huffman coding of literals is a thing lz4 does not do at all. The
frame sizes are larger than the block sizes because each block restarts the match
finder, which loses the cross-block matches a repetitive body lives on.

## What is verified, and how

**Interoperability is the acceptance criterion, and it is checked both ways.**

`scripts/conformance.py` takes every stream `examples/vectors` prints — every
level, every block type, every chunk size, Zip64, descriptors, ZipCrypto — and
hands it to Python's `zlib`, `gzip` and `zipfile`, which have to read it back.
`scripts/interop.py` goes the other way: it writes archives with Python's
`zipfile` and `tarfile` in the shapes our own writer would never produce — a data
descriptor because the sink it wrote to could not seek, a forced Zip64 header,
GNU long names — and pins them as tests.

The readers are checked against the vectors the specifications publish: the
xxHash-32 of the empty input and of `a`, the CRC-32C of `123456789`, gzip's own
fixed-Huffman streams. And against broken input that must be refused: a flipped
payload byte, a truncation, a bad header, a back-reference reaching before the
start of the output, a block that claims more than it holds.

The gate, on every push and all four backends:

```
moon check --target all --deny-warn     # a warning is an error
moon build --target all
moon test  --target all                 # wasm, wasm-gc, js, native
moon fmt          && git diff --exit-code
moon info --target all && git diff --exit-code
python3 scripts/conformance.py < vectors.txt
python3 scripts/interop.py && git diff --exit-code
```

## What it reads and what it writes

The DEFLATE reader takes **all three block types**, including the dynamic Huffman
blocks that zlib, gzip and every browser actually emit. A reader without those
reads almost nothing in practice, which is why it was not a later step.

The DEFLATE writer emits all three as well, and chooses per block: a dynamic
candidate is written to a probe writer, measured, and re-emitted only if it won;
the fixed and stored costs are arithmetic. This is what zlib does, and it is why
`blocks=Auto` is the default.

Both containers **check their checksum and their length** on the way back.

Every writer is **reproducible**: gzip writes a zero modification time and no file
name, ZIP stamps the epoch, tar takes the time it is given, and ZipCrypto derives
its twelve-byte header from a hash of the name, time and password rather than a
random source. The same input gives the same bytes, so two builds can be compared
and a cache entry can match.

## Where the checksums live

CRC-32, Adler-32 and CRC-32C are at the root, because more than one container
specifies them — `gzip` puts CRC-32 in its trailer, `zip` in every entry, `snappy`
puts CRC-32C in every chunk — and none of them should import another to reach it.
Each has a struct beside the one-shot function (`Crc`, `Adler`, `Castagnoli`) for
a body that is compressed as it arrives and cannot be checksummed in one call.
When the checksum package in `mooncrypt` lands they move there and are re-exported
from here.

## Why one package per format

A subpackage already isolates what a caller carries: importing `moonzip/gzip` does
not bring `snappy` with it. There is no umbrella package re-exporting them all —
that would undo exactly what the split achieves, and `pub using` cannot carry an
enum's constructors through anyway.

The vocabulary is shared and fixed: `Refused` with its offset for every failure,
`BytesView` in and `Bytes` out, `raise` only on the reading side, `~` for a
default a caller may want to change and `?` for one that changes behaviour rather
than size.

## Install

```bash
moon add moonbitstack/moonzip
```

## Licence

Apache-2.0.

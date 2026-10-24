# Roadmap: what is still missing

Written down rather than improvised, because the interface is the part that is
expensive to change later. Each section names the format, the specification, the
entry points it will have, and — the part that matters — *why* those and not
others.

Everything below follows the vocabulary the ten existing packages already use:

- `BytesView` in, `Bytes` out.
- `raise @moonzip.Refused` on the reading side only. A writer has no input to
  distrust, so a writer does not raise.
- `~` for a parameter with a default the caller may want to change, `?` for one
  that changes behaviour rather than size (`limit`, `password`, `name`).
- One package per format, named after the format. No umbrella package.
- Streaming `Writer`/`Reader` where the format has a natural unit to stream — a
  chunk, a block, a frame — and not where it does not.

## zstd — done

The one with the widest reach: every Linux distribution, every database, and
`Content-Encoding: zstd` on the web. Three layers, and none of them is optional
for a reader that expects to read real files:

| Layer | What it is |
|:--|:--|
| Frame | Magic, frame header with window and content size, block loop, optional content checksum |
| Block | Raw, RLE, or compressed: literals section, then sequences |
| Entropy | Huffman for literals, FSE (finite-state entropy) for literal lengths, match lengths and offsets |

```moonbit
pub fn zstd(data : BytesView, level~ : Int32 = 3, content_size~ : Bool = true) -> Bytes
pub fn unzstd(data : BytesView, limit? : Int32, checksum~ : Bool = true) -> Bytes raise @moonzip.Refused

pub fn Writer::new(level~ : Int32 = 3) -> Writer
pub fn Writer::push(self : Writer, data : BytesView) -> Bytes
pub fn Writer::finish(self : Writer) -> Bytes

pub fn Reader::new(limit? : Int32, checksum~ : Bool = true) -> Reader
pub fn Reader::push(self : Reader, data : BytesView) -> Bytes raise @moonzip.Refused
pub fn Reader::finish(self : Reader) -> Bytes raise @moonzip.Refused
```

The work is the FSE decoder and the Huffman decoder, in that order: FSE is the
harder of the two (two interleaved states, a table built from a normalised
distribution, a bitstream read backwards), and nothing in the format reads
without it. The encoder can legitimately start as raw and RLE blocks — a
conforming zstd stream that does not compress is still a conforming zstd stream —
and grow a real encoder afterwards. That is the same road DEFLATE took here, and
it is why `blocks=Stored` exists.

Level mapping will follow zstd's own table, as `level` here follows zlib's.

## brotli — the one that is left

Everything else in this module is done and verified in both directions. This is
the last format, and it is the largest single piece in the set — not because the
idea is harder than FSE, but because there are more independent mechanisms and
each one has its own bit layout.

What it needs, in the order the reference decoder meets them:

| Piece | Where to read it | Size |
|:--|:--|:--|
| stream header, meta-block header | `c/dec/decode.c:243-340` | WBITS, MNIBBLES, MLEN, the uncompressed and metadata escapes |
| Huffman codes, both families | `decode.c:807-1060` | simple codes, and complex ones with a code-length code over 18 symbols and 16/17 run-length codes |
| context map | `decode.c:1060-1160` | an RLE + MTF alphabet, then a prefix code over it |
| block switching | `ReadBlockSwitchInfo` | three independent categories (literals, insert-and-copy, distance), each with its own type code and count code |
| literals with context modelling | `decode.c` literal loop | the context is a function of the last two bytes and the mode, which is what makes brotli's literal section better than DEFLATE's |
| commands | `ReadCommand` | 704 insert-and-copy symbols over a two-dimensional table |
| distances | `decode.c` distance loop | 16-entry ring, plus 48 codes, plus the dictionary references |
| **static dictionary** | `c/common/dictionary.bin` | 122,784 bytes, 13,504 words |
| **transforms** | `c/common/transform.c` | 121 entries: prefix, one of ten transform kinds, suffix |

The dictionary is the part that decides whether a decoder is real. Brotli at any
quality above the trivial uses dictionary references for words it recognises, so
a decoder without it reads most of a real file correctly and then corrupts on the
first common word — the worst failure mode there is. It is 122 KB of data, which
belongs in a generated `data.mbt` rather than in a hand-written table:

```
python3 - <<'EOF'   # roughly
data = open('.temp-ref/brotli/c/common/dictionary.bin','rb').read()
# emit a base64 string constant; the transforms come from transform.c
EOF
```

The judge is the `brotli` CLI (1.2.0, at `/mingw64/bin/brotli`) and Node's
`zlib.brotliCompressSync` — two independent ones, which is one more than most
formats here got.

The writer, once the reader exists, can start where zstd's did: a legal stream
that only stores, then LZ77 with simple prefix codes and a single block type and
no context modelling. Brotli's encoder is a project of its own; its decoder is
the part that makes the format readable at all.

## lzma and xz — done

Both landed: the range coder, the LZMA codec, the `.lzma` container and the xz
container over LZMA2 chunks. Each is verified both ways against Python's `lzma`,
which is the reference implementation the format names. The one detail worth
remembering: xz pads a block to a four-byte boundary **before** its check, and a
writer that pads afterwards produces a stream only it can read.

```moonbit
// the codec
pub fn lzma(data : BytesView, preset~ : Int32 = 6) -> Bytes
pub fn unlzma(data : BytesView, limit? : Int32) -> Bytes raise @moonzip.Refused

// the container
pub fn xz(data : BytesView, preset~ : Int32 = 6, check~ : Check = Crc64) -> Bytes
pub fn unxz(data : BytesView, limit? : Int32) -> Bytes raise @moonzip.Refused
```

LZMA is a range coder with a binary-probability model, which makes it a different
kind of program from everything above: there is no bitstream to align, no block
to measure, and the state is a table of probabilities updated per decision. The
decoder is roughly a thousand lines and almost impossible to get right by
inspection — the tests will lean on vectors from `xz` itself rather than on
round-trips.

`unxz` reads the container: stream header and footer, the block header, and the
index. Writing `xz` means writing the index and the check (CRC-32, CRC-64 or
SHA-256), which is a smaller job than the codec underneath.

## 7z — done

The container is built and reads real archives. What it cost, in the order it
cost it:

**The length encoding.** `n` bytes carry `7n` bits, and the *first* byte holds the
high bits — `80 97` is 151. Reading the continuation bytes as if they sat above the
first byte's payload is a factor of 256 out. It shows up as an unpacked size
nothing can produce, and only for values at or above 16384, so every small test
passes.

**The selector for COPY.** A coder id of length zero is not a missing coder; it is
how "no compression" is spelled. A reader that treats it as empty refuses every
stored archive.

**Boxed records.** `Array::make(n, record)` with a record that has mutable fields
gives every slot the same box. The symptom is an archive whose every entry is the
last one written, and it looks exactly like a misaligned file table.

What reads, verified against the 63 archives 7-Zip itself wrote (the fixtures
shipped with py7zr): COPY, LZMA, LZMA2, BZIP2, DEFLATE, the delta filter, folded
directories, substream tables, names in UTF-16, times and attributes. 27 of the 42
small fixtures decode; the rest are refused by name:

| Refused | Id |
|:--|:--|
| AES-256 encryption | `06 f1 07 01` |
| x86, ARM, ARMThumb, PPC, SPARC, IA64 branch filters | `03 03 xx xx` |
| BCJ2 (a folder that is a graph, not a chain) | `03 03 01 1b` |
| PPMd | `03 04 01` |
| LZ4 and Zstd coders | `04 f7 11 04`, `04 f7 11 01` |

Encryption is the one that matters for a "supports archives" claim, and it is also
the natural moment to close `zip`'s AES gap: both want the same cipher and the same
passphrase-derived key, so they should be written together.

The writer emits COPY, LZMA or LZMA2, solid or one folder per file, with an
uncompressed directory. That last part is the honest limit: 7-Zip compresses the
directory too once there are enough entries to pay, and our writer does not.

## bzip2 — done

Implemented, tested both ways against libbz2, and streaming. The interesting part
of this one is *how* it was finished, because the first two attempts failed and the
reason is worth keeping.

An earlier version of this file held a wire format "derived from a real stream" —
dumping `bz2.compress` and reading the bits back. Four of those derived facts were
wrong:

| Derived, and wrong | What `decompress.c` actually does |
|:--|:--|
| `nGroups` is 3 bits **plus 2** | it is the value: `GET_BITS(nGroups, 3)`, then a range check of 2..6 |
| the selector **count** is a unary run | it is a **15-bit field**: `GET_BITS(nSelectors, 15)` |
| a bad code length is **re-read as 5 bits** | it is a data error: `if (curr < 1 || curr > 20) RETURN(BZ_DATA_ERROR)` |
| `RUNA`, `RUNB` are 1 and 2 | they are 0 and 1: `BZ_RUNA 0`, `BZ_RUNB 1` |

Every one of them is the kind of wrong that still compiles and still round-trips
against your own encoder, because the writer and the reader share the mistake. The
first stream from a foreign encoder — Python's — hit the unary selector count at
once, decoded one table perfectly, then read the payload as code lengths.

The lesson, recorded so a future session does not repeat it: **read the reference
source, not the bytes.** The clone lives in `.temp-ref/` (gitignored) and is a
`git clone --depth 1 https://github.com/libarchive/bzip2` away:

```
.temp-ref/bzip2/decompress.c   -- GET_MTF_VAL (l.74), the whole block (l.240-500)
.temp-ref/bzip2/huffman.c      -- BZ2_hbCreateDecodeTables, the perm/base/limit trio
.temp-ref/bzip2/compress.c     -- sendMTFValues, the table-selection loop
.temp-ref/bzip2/randtable.c    -- the 512-entry mask table
```

Two facts that only the source settles:

- Blocks are **not padded between them**. `bsFinishWrite` runs once, at the end of
  the stream, so a block boundary can fall inside a byte. A streaming reader
  therefore has to carry a bit position, not a byte offset — which is why
  `Reader` keeps an accumulator rather than an index.
- `state_in_len` is capped at 255 and a run of four or more is written as four
  bytes plus `length - 4`, and that count byte is itself added to the symbol set.

## Where the reference sources are

No compiler and no package index on this machine, so a judge has to be something
that already runs. Three do:

| Format | Judge | Where |
|:--|:--|:--|
| brotli | `brotli` CLI, and Node's `zlib.brotliCompressSync` | `/mingw64/bin/brotli` |
| zstd | **Node 22's `zlib.zstdCompressSync` / `zstdDecompressSync`** | `node -e "require('zlib').zstdCompressSync"` |
| 7z | none that runs — see below | — |

Node having zstd is the finding that unblocks it: `node -e` is a two-way judge for
both remaining codecs, exactly like Python's `lzma` was for ours.

7z is different. There is no `7z` binary, no compiler to build one, and no
`py7zr` (its dependencies are not installable). What there *is*:

```
.temp-ref/py7zr/py7zr/properties.py    -- property ids (0x00..0x19) and coder ids
.temp-ref/py7zr/py7zr/archiveinfo.py   -- every structure, read and write, in one file
.temp-ref/py7zr/tests/data/*.7z        -- 63 archives written by real 7-Zip
```

That makes the **reader** verifiable — 63 real archives with known contents is a
stronger judge than a self round-trip — and the writer only structurally
verifiable. Say so in the docs rather than implying otherwise.

## What is not on the list, and why

**bzip2.** Burrows–Wheeler plus move-to-front plus Huffman. It is in Python's
standard library, so "parity" argues for it; it is also almost unused in new work,
and its block-sorting transform is a self-contained week of work that would not
make any other format easier. It is a `Codec` for `zip` before it is a package.

**Split and spanned volumes.** A `zip` written across several files is a filesystem
concern dressed as a format concern: the same archive with a different name per
part. When it lands it will be a wrapper that takes a writer and a part size, not a
flag on `zip`.

**AES in zip.** Listed under 7z above because that is when it becomes cheap: the
cipher, the key derivation and the authentication are the same code.

## The order, and what each one proves

1. ~~bzip2~~ — done. The block sort, and the entropy layer that makes a sorted
   block encodable.
2. ~~7z~~ — done. The container, and the proof that the architecture holds:
   `sevenz` reads COPY, LZMA, LZMA2, BZIP2, DEFLATE and delta without a line of
   codec code of its own. Two of the mistakes it cost are recorded in the README's
   7z section, both of the kind that pass every small test.
3. **brotli** — proves the dictionary and the context model. Nothing else here
   looks like it: a 122 KB static dictionary, ten transforms, and literal contexts
   keyed on the last two bytes.
4. ~~zstd~~ — done. The entropy layer: FSE in both directions, Huffman literals,
   sequences and repeat offsets. Its judge is Node's `zlib`, which is libzstd
   compiled in — the first referee here that is not Python.

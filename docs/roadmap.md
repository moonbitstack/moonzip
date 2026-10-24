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

## zstd — RFC 8878

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

## brotli — RFC 7932

The one HTTP already uses. Larger than zstd in code and smaller in output.

| Piece | Where the difficulty is |
|:--|:--|
| Meta-block loop | A header of five fields whose meanings depend on each other |
| Prefix codes | Simple codes (1–4 symbols, direct encoding) and complex ones; the code-length code is itself brotli's |
| Context modelling | Six literal contexts keyed on the last two bytes |
| Static dictionary | 122,784 bytes in 13,504 words, with ten transforms and a shared prefix/suffix tree |
| Distance ring buffer | The last four distances, and the "distance is the same again" shorthand |

```moonbit
pub fn brotli(data : BytesView, quality~ : Int32 = 11, window~ : Int32 = 22) -> Bytes
pub fn unbrotli(data : BytesView, limit? : Int32) -> Bytes raise @moonzip.Refused
pub fn Reader::new(limit? : Int32) -> Reader        // and push/finish
```

The static dictionary is data, not code, and it is the reason a naive
implementation reads most streams and misreads the rest. It will be generated into
a `.mbt` file by a script, from the table the RFC publishes, so it can be checked
rather than typed.

Quality is brotli's own scale (0–11), not a deflate-style 0–9: it selects between
what are effectively different algorithms, and pretending otherwise would be a
worse interface.

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

## 7z — a container over codecs, not a format of its own

7z is to LZMA what zip is to DEFLATE: a directory, an encoded header, and a codec
identified by an identifier rather than assumed. That is why it comes last and why
it will reuse `zip`'s shape — `Entry`, a `Codec` trait, a central index.

```moonbit
pub fn sevenz(entries : ArrayView[Entry], codec~ : &Codec = ...) -> Bytes
pub fn unsevenz(data : BytesView, limit? : Int32) -> Array[Entry] raise @moonzip.Refused
```

Its header is itself an LZMA stream in the common case, so `unsevenz` cannot be
tested before `unlzma` works. Its encryption (AES-256 with a SHA-256 key derived
from a passphrase by iterated hashing) is the place where "supports encryption"
becomes a real claim rather than a checkbox — and it is also the natural time to
revisit zip's gap, since the two would share the AES and the KDF.

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
2. **7z** — proves the architecture: a `Codec` seam that already exists in `zip`,
   reused rather than reinvented. Its header is itself an LZMA stream, so it can
   start now, and the codec it needs is the one `xz` already uses.
3. **brotli** — proves the dictionary and the context model. Nothing else here
   looks like it: a 122 KB static dictionary, ten transforms, and literal contexts
   keyed on the last two bytes.
4. **zstd** — proves the entropy layer. FSE written once serves zstd, and the
   Huffman half is a second opinion on `deflate/huffman.mbt`.

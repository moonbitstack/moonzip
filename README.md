# moonzip

Compression for MoonBit. Thirteen formats, one per package, each with the
interface its own specification argues for — and no dependency beyond `moonbase`
and `mooncrypt` (the checksums, and the AES primitives behind ZIP's encryption).

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
| `zip` | The ZIP archive, with Zip64, descriptors, ZipCrypto, WinZip AES and volumes | APPNOTE 6.3 |
| `tar` | ustar and pax, and `.tar.gz` on top | POSIX pax |
| `lz4` | The block and frame formats, with xxHash-32 | lz4 block, frame |
| `snappy` | The block and framing formats, with CRC-32C | Snappy |
| `lzma` | The LZMA codec and the `.lzma` container | LZMA SDK |
| `xz` | The xz container over LZMA2 | xz file format |
| `bzip2` | Burrows-Wheeler, move-to-front and Huffman, both directions | bzip2 |
| `sevenz` | The 7z container: folders of coders, solid or separate | 7z format |
| `zstd` | Frames, blocks, FSE and Huffman | RFC 8878 |
| `brotli` | Meta-blocks, contexts, block types and the 122 KB dictionary | RFC 7932 |

Run any of them with `moon run src/examples/<name>`:

- `minimal` — the smallest program: compress and read back one buffer.
- `tour` — the surface in one go: deflate, gzip, zlib and brotli, the two checksums, and a tampered stream refused.
- `formats` — every codec, one-shot, with the size it reached and a round-trip check.
- `throughput` — megabytes per second for the one-shot codecs, best of several runs.
- `stream` — the streaming pair, both ways, on a body taken a piece at a time.
- `checksums` — CRC-32, Adler-32 and CRC-32C, one-shot and streamed a piece at a time.
- `archive` — zip (Zip64, descriptors, a password) and tar, tar.gz and 7z.
- `bundle` — a small release packer: stream-compress, wrap in four containers, read back.
- `vectors` — the byte streams handed to an external checker for conformance.

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
| `level` | 6 | The usual default; each level maps to the search depths the format's reference tables give it, so a level means the same here as anywhere |
| `window` | 32768 | The most DEFLATE allows, and the only size a reader can be assumed to handle |
| `chain` | from `level` | For a caller who would rather set the depth than pick a level |
| `blocks` | `Auto` | The writer measures a dynamic candidate, a fixed one and a stored one per block and keeps the smallest |
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

The only state carried between calls is the window a back-reference can reach,
plus a few bytes of running checksum — on both sides. `deflate`, `gzip`, `zlib`
and `bzip2` have the pair; `bzip2`'s bound is one whole block, which is what its
level sets, because the sort cannot begin until the block is complete. `zip` has
a writer that hands back each member's bytes as it adds them and a reader that
walks local headers from the front, which is the only way to read an archive that
is still arriving.

The block and frame formats — `lz4`, `snappy`, `zstd`, `brotli`, `lzma`, `xz` and
`7z` — are one-shot on purpose. Their encoders pick their tables after seeing the
whole input, so a pair that buffered everything and compressed at `finish` would
be a streaming interface with none of the memory saving. They take a buffer and
give one back; a caller holding a stream gathers it first.

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
@zip.zip(entries[:], password="hunter2", aes=256)         // WinZip AES-256, AE-1
@zip.zip(entries[:], password="hunter2", aes=256, ae=2)   // AE-2, CRC zeroed
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

**On encryption**: two schemes, and only one of them is a security boundary.

ZipCrypto is the cipher the format called encryption for fifteen years, and it is
broken — a known-plaintext attack recovers the keys from a dozen bytes. It is here
because archives in the wild still carry it, and opening one should not need a
second tool. It is not a security boundary, and nothing here will claim it is.

WinZip AES is the real one. `aes=128`, `192` or `256` picks the key length; the
bytes are encrypted in counter mode under a key derived by PBKDF2-HMAC-SHA1 with a
thousand iterations, authenticated with an HMAC-SHA1 tag truncated to eighty bits,
and stored as salt, verification value, ciphertext and tag. Both headers carry
method 99 and a `0x9901` extra field naming the real method and the strength. AE-1
(the default) keeps the CRC; AE-2 zeroes it, because the tag already proves
integrity. Reading catches a wrong password from the two-byte verification value
and a tampered payload from the tag, both before a byte is returned. The test
suite reproduces the published WinZip AES vector byte for byte, which is what
makes an archive written here open in 7-Zip and WinZip and one written there open
here.

**Volume splitting**: one archive carried in several files, `archive.z01`,
`archive.z02`, … and finally `archive.zip`. A split archive is the same bytes cut
at fixed boundaries — the central directory is still the last thing in the stream
— so rejoining the pieces in order is the archive, and every reader understands
it. `volume_names` gives the names the convention expects; the pieces are ordinary
bytes, because this package never touches a file system.

```moonbit
let parts = @zip.zip_split(entries[:], 65536)  // volumes of at most 64 KiB
@zip.volume_names("archive", parts.length())   // ["archive.z01", ..., "archive.zip"]
let back = @zip.unzip_split(parts)             // if it arrives as several files
```

Two models, and the difference is what the headers say. `split` cuts a finished
archive into byte ranges and leaves every offset absolute — the pieces must be
rejoined before anything reads them. `zip_spanned` writes the older multi-disk
form instead: each member's directory record carries the disk it starts on and its
offset from that disk's first byte, and the end record names the last disk and
where the directory begins, which is what an `unzip` that reads disk by disk
expects. `unzip_spanned` joins the disks, translates every disk-relative offset
back to one coordinate space, and reads the result.

```moonbit
let disks = @zip.zip_spanned(entries[:], 65536)  // true spanned disks
@zip.unzip_spanned(disks)                        // disk numbers translated back
```

The end record has to lie wholly on the last disk, or a reader handed that piece
alone cannot find the directory, so the last disk begins at the largest multiple
of the size that does not pass it. Every disk before it is exactly the size asked
for; the last is the one that may be a little larger. Offsets stay in thirty-two
bits, so a member that would need Zip64 is refused rather than written with a
field it cannot agree with.

Verified against libarchive (`bsdtar`) on the concatenated disks: a member
recorded as disk 1, relative offset 3 is read at byte 131, which only works if the
disk number is honoured — and it extracts byte for byte. Info-ZIP `unzip` reads
the byte-range `split` form after rejoining, but says outright that it has no
multi-part support, so it is not the tool for this one.

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

@xz.xz(body[:])                // the container, one block, CRC-64
@xz.unxz(packed[:])            // header, block header, index and footer checked
```

The xz layer is the LZMA2 chunk framing: a control byte that says how much state
to discard, the sizes, and a properties byte when the model changes. The
specification puts the block's padding *before* its check rather than after —
which is the detail that made the first version of this stream readable by us and
rejected by everybody else.

Levels 0–9 map to the same dictionary sizes `xz` uses. The encoder is a greedy
hash-chain parse of moderate effort — a stream real
decoders read, not the last few percent.

This is the codec that xz and 7z are built on, which is why it is a package of its
own: the container work comes next, and it will not need a second codec.

## bzip2

Sort the block's rotations, and equal contexts end up adjacent. Read the last
column, and the byte after each context is where the next one starts. That is the
whole idea, and the three stages after it exist to make the result encodable:
move-to-front turns "the same byte as last time at this context" into a zero, a
run of zeros becomes two symbols, and Huffman codes what is left.

```moonbit
@bzip2.bzip2(body[:], level=9)      // 900k blocks
@bzip2.bunzip2(packed[:])           // block CRCs and the combined one checked
```

The encoder is a real one: an exact block sort by prefix doubling, and six Huffman
tables assigned by a cost pass and rebuilt from what they were given, four times
over — the reference's own loop. On the body in the table below it lands within a
per cent of what `bzip2` writes.

Two details cost time and are worth naming, because both produce streams that
look fine and read wrong:

- The selector count is a **fifteen-bit field**, not a unary run. A reader that
  assumes unary decodes the first table perfectly and then reads the data as code
  lengths.
- Blocks are **not padded**. `bsFinishWrite` is called once, after the trailer, so
  a block boundary can fall in the middle of a byte — which means a streaming
  reader has to carry a bit position, not a byte offset.

## 7z

Not a codec — a container whose compression method is a property of each *folder*.
A folder is one compressed stream, and it can hold several files at once, which is
what "solid" means: the compressor saw all of them together, so a phrase repeated
across two files is paid for once and neither can be read without the other.

```moonbit
@sevenz.sevenz(members[:], how=@sevenz.Method::Lzma2, solid=true)
@sevenz.un7z(archive[:])       // folder, substream and signature checksums verified
@sevenz.names(archive[:])      // the directory only, without touching the data
```

The reader understands folders whose coders are a straight chain, over **COPY,
LZMA, LZMA2, BZIP2, DEFLATE and the delta filter**, and reads real 7z archives
including ones whose directory is itself a compressed stream — which is the normal
shape, because a directory that is a stream is how a thousand-file archive keeps
its index under a few kilobytes.

**What it refuses, by name rather than by guessing:** AES encryption (`06 f1 07 01`),
the branch filters (`03 03 …`: x86, ARM, ARMThumb, PPC, SPARC, IA64), BCJ2 (a
folder that is a graph rather than a chain), PPMd, and the LZ4 and Zstd coders.
The error carries the method id, so a caller learns what it met.

Three things about this format are worth remembering, because each one is a
plausible mistake that produces a stream only its author can read:

- The length encoding is `n` bytes for `7n` bits, with the *first* byte holding the
  high bits: `80 97` is 151, not 38656. A writer that gets this wrong is correct
  for every value below 16384.
- A coder id of length zero is not "no coder" — it is how COPY is spelled.
- A file table entry is a *boxed* record with mutable fields; filling an array with
  one gives every slot the same box, and every entry becomes the last one written.

The writer emits an uncompressed directory, which is legal and which any reader
must accept. The reader accepts both forms.

## zstd

Two entropy coders over one LZ77 parse. FSE is an ANS variant — a state machine
whose transitions are probability-weighted — which is what lets a symbol cost a
fractional number of bits; Huffman codes the literals and FSE codes everything
else.

```moonbit
@zstd.zstd(body[:], level=3)
@zstd.unzstd(packed[:])
```

**The reader is complete**: all three block types, literals raw, RLE or
Huffman-coded with one or four streams, every FSE table mode (predefined,
single-symbol, described, repeated), repeat offsets including the
zero-literals shift, skippable frames and concatenated frames.

**The writer is real but modest**: an LZ77 parse coded with the *predefined* FSE
tables and raw literals. That is a legal frame, and it
compresses — 184,000 bytes of English text to 3,042 — but it leaves the two
things the reference encoder does for ratio: per-block table selection, and
Huffman coding of the literals.

Three things about this format cost time and are worth naming:

- The bitstreams are read **backwards**. The last byte holds a stop bit: 0-7 zeros
  and then a one, with the data below it.
- An FSE decoding table seeds each symbol's next-state counter at that symbol's
  *count*, not at where its block of states begins. Getting that wrong decodes
  every symbol correctly and every next state wrongly — which reads as "the first
  sequence is right and everything after it drifts".
- The encoder must not spend bits on the last sequence's state update, because the
  decoder does not read one; it seeds the three states from those symbols instead.

## brotli

Three ideas stacked on the same LZ77 skeleton as DEFLATE, each with its own
chunk of the format:

- **Block types.** Literals, commands and distances are three separate symbol
  streams, and each may switch between up to 256 sets of prefix codes, with the
  two most recent types addressable in three bits. A file with prose and a table
  of numbers gets one model for each.
- **Literal contexts.** Every literal is coded with one of 64 sub-alphabets,
  chosen by the two bytes before it — a hand-written model of where in a UTF-8
  character the reader is. This is where most of brotli's edge over DEFLATE comes
  from on text, and it is the reason `utf8` and `signed` are context *modes*
  rather than a detail.
- **A static dictionary.** 13,504 common words in several languages, plus 121
  transforms over them, reachable by a distance larger than the window. A word the
  encoder recognises costs a distance code instead of its letters.

```moonbit
@brotli.brotli(body[:], window=22)   // window is 10 to 24
@brotli.brotli(body[:], quality=11)  // search hardest; quality is 0 to 11
@brotli.unbrotli(packed[:], limit=1 << 24)
```

**The reader is complete**: both prefix-code spellings, all four context modes,
block switching for all three streams, context maps with run-length coding and
move-to-front, the distance ring with all sixteen short codes, and every one of
the 121 dictionary transforms. It reads streams at qualities 0 through 11 and windows 10 through 24, including
quality 11 on English prose, which is where the dictionary does its work.

**The writer is greedy LZ77 with three of brotli's four ideas.** A hash chain and
Huffman codes from exact counts at every quality; at quality 10 and 11, literal
contexts, a split command stream and the static dictionary. `quality` (0 to 11,
default 9) is how much of that is on, and how far the chain is walked at each
position: more effort, never more bytes, and 0 is the single-candidate "fast"
search LZ4 ships. On the body in the table below — 184,000 bytes of repetitive
English — quality 9 reaches 682 bytes, ahead of gzip at 1,983 and zstd at 3,042,
because one long match is worth more than everything the fancier models add.

- **Literal contexts.** The writer picks a context mode — `UTF8` for text, `LSB6`
  for binary — counts every literal in one of 64 sub-alphabets keyed by the two
  bytes before it, and then groups those sub-alphabets into at most six codes. The
  grouping is a recursive bisection: each round splits the group whose split pays
  best, and stops when no split pays or the cap is reached. The routing table that
  says which context uses which code is sent with the stream, so a body whose
  contexts look alike comes out with one code and one bit of map.
- **A split command stream.** The command stream may be cut in two, each half
  carrying its own prefix code.
- **The static dictionary.** Words the format already knows are coded as a
  dictionary reference — a distance past the window that names `(transform, word)`
  — instead of their letters. The writer indexes the 13,504 words by their first
  four bytes and probes each position twice: once as spelled, once with the first
  letter lowercased, so a sentence-initial `Time` costs the same code as `time`.
  It then tries the 54 transforms whose prefix is empty, which is what makes them
  reachable by that probe: the word still starts at the position being searched
  and only the bytes after it differ. That covers `word + " "`, `word + "."`,
  `word + ", "`, `word + " the "` and the capitalised spelling of each — the
  punctuation that follows most words in prose. A transform's affix is not part of
  the copy length: the command carries the *word's* length, which selects the
  bucket, and the transform decides how much comes out, so `time` with the
  space-suffix transform is a copy of four bytes that produces five.

Both searches **price what they are choosing instead of estimating it**: the
candidate code is written to a throwaway bit stream and counted. An estimate of
"so many bits per used symbol" is wrong by enough to accept splits that then come
out larger than the stream they were meant to shrink, which is exactly what
happened here first — a body of short repeated phrases grew by six bytes at
quality 11. With exact pricing, asking for context modelling or a command split
can no longer cost bytes, and a test pins that.

On this repository's own documentation — README, homepage and guide, 100,350 bytes
— quality 9 gives 28,333 and quality 11 gives 26,269, which is 7.3% smaller. The
literal context model is 531 of those bytes, the command split 60, and the
dictionary 1,444 — by far the largest, because prose is mostly words the
dictionary already has, and the affix transforms alone are 500 of them. For scale,
the reference encoder reaches 25,925 on the same bytes at quality 9 and 23,515 at
quality 11, so this writer is 9% behind at nine and 12% behind at eleven. What it
still does not do is split the *literal* stream, and reach the transforms whose
prefix is not empty; those are most of what is left.

All three new forms are checked against the reference decoder, not just this one:
a quality-11 stream over a 99,446-byte body, whose header declares two command
block types and a literal context map where quality 9 declares one block type and
one code, decodes through `brotli 1.2.0` to the same bytes — including the
dictionary references, which the reference reader resolves against its own copy of
the blob. Text and binary bodies were checked the same way, because the two take
different context modes.

Four things about this format cost real time:

- **The code-length code is written as a prefix code**, not as four raw bits per
  value. It looks like a fixed-width field and is not, and a writer that assumes
  otherwise produces a stream whose trees are almost right.
- **A code-length code with one symbol costs zero bits.** The reference zeroes
  that symbol's width after writing the header. A reader that charges one bit per
  run length desynchronises on the very next symbol, and the streams that hit it
  are the ones where every literal has the same width — the alphabet, not the
  prose.
- **The dictionary transform table holds fragment *ids*.** The 49-prefix table is
  reached through a second indirection; indexing it with the transform's own
  position reads past its fifty entries.
- **The simple prefix-code form does not transmit widths.** The reader derives
  them from the number of symbols and always gives the shortest one to the symbol
  it read first, so a writer has to assign widths the same way — with three
  symbols the frequency-based choice and the positional one disagree.

## The formats chosen for speed

`lz4` and `snappy` trade ratio for decode speed, and the numbers below are what
the trade costs on the same body — 184,000 bytes of English text with a periodic
tail, printed by `src/examples/stream`.

| Format | Bytes | Of the original |
|:--|--:|--:|
| gzip | 1,983 | 1.1% |
| lz4 block | 1,997 | 1.1% |
| lz4 frame (three 64 KiB blocks) | 4,576 | 2.5% |
| deflate, dynamic blocks | 2,661 | 1.4% |
| zlib | 2,667 | 1.4% |
| snappy block | 9,884 | 5.4% |
| snappy frame (three 64 KiB chunks) | 12,439 | 6.8% |
| bzip2 | 853 | 0.5% |
| xz | 468 | 0.3% |
| lzma, alone | 415 | 0.2% |
| zstd | 3,042 | 1.7% |
| brotli | 682 | 0.4% |
| — nothing | 184,000 | 100% |

The three at the bottom are the block-sorting and range-coding end of the field:
they find the repetition that DEFLATE's 32 KiB window cannot see and spend a lot
of setup finding it. That lz4 beats DEFLATE here is the body's fault too: four
thousand repetitions of one sentence are exactly what a two-byte back-reference is
for. On prose, DEFLATE
wins, because Huffman coding of literals is a thing lz4 does not do at all. The
frame sizes are larger than the block sizes because each block restarts the match
finder, which loses the cross-block matches a repetitive body lives on.

## Throughput

Sizes are one axis; the other is time. These are release-build numbers from
`src/examples/throughput` on one machine, best of several runs, over a 1.5 MB body
of words and numbers that compresses 3.4 to 1. A rate on a shared machine is a
range rather than a constant, so read them as orders of magnitude.

| Codec | Write MB/s | Read MB/s |
|:--|--:|--:|
| `deflate` | 9 | 50 |
| `gzip` | 8 | 43 |
| `zlib` | 9 | 49 |
| `zstd` | 20 | 52 |
| `brotli` (quality 9) | 1.4 | 54 |

The same body through C zlib on the same machine — `zlib.compress(_, 6)` from
Python — writes at about 18 MB/s and reads at 200–350 MB/s depending on how busy
the machine is. The deflate writer is therefore within a factor of two of zlib.
The inflate reader is a seventh to a quarter of zlib's decode rate: it brushes the
quarter line this library set for itself rather than clearing it, and the reason is
structural, not a missed constant. The Huffman decoder walks a code one bit at a
time; the table-driven decoder that would close the gap has to look ahead across
byte boundaries, which this reader's stored-block alignment does not allow — a
prototype broke the compressed-to-stored transition and was not shipped. Saying so
is better than a number taken on a body of one repeated sentence, where the rate
measures a memcpy more than a decoder.

`brotli`'s write rate is the price of its search: quality 9 walks up to 256 chain
candidates at each position. `quality=1` is several times faster for a few per cent
more bytes, which is the trade the knob exists to expose.

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
name, ZIP stamps the epoch, tar takes the time it is given, ZipCrypto derives its
twelve-byte header from a hash of the name, time and password rather than a random
source, and AES derives its per-entry salt from the name, time, entry offset and
password — folding the offset in so two same-named entries still get distinct keys.
The same input gives the same bytes, so two builds can be compared and a cache
entry can match.

## Where the checksums live

CRC-32 and Adler-32 come from `mooncrypt`'s `sum` package and are re-exported at
the root, because more than one container specifies them — `gzip` puts CRC-32 in
its trailer, `zip` in every entry — and none of them should import another to reach
it. CRC-32C stays here, because `mooncrypt` does not carry it and `snappy` puts it
in every chunk. Each has a struct beside the one-shot function (`Crc`, `Adler`,
`Castagnoli`) for a body that is compressed as it arrives and cannot be checksummed
in one call.

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

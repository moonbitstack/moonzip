# moonzip

Compression for MoonBit. Thirteen formats, one per package, each with the
interface its own specification argues for — and no dependency beyond `moonbase`
and `mooncrypt` (the checksums, and the AES primitives behind ZIP's encryption).

```moonbit
let body = @utf8.encode("the quick brown fox jumps over the lazy dog. ")
let small = @gzip.gzip(body[:])
let back = @gzip.gunzip(small[:])     // raises if the checksum disagrees
assert_eq(back, body)

let archive = @zip.zip([@zip.Entry::new("readme.txt", body)][:])
let members = @zip.unzip(archive[:])
assert_eq(members[0].name, "readme.txt")
assert_eq(members[0].data, body)
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

<!-- nocheck -->
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

## The long-match strategy

The writer can parse a block two ways, and the choice is a parameter, `strategy`.

```moonbit
let text : Array[Byte] = []
for _ in 0..<3000 {
  for b in "the quick brown fox jumps over the lazy dog. " {
    text.push((b.to_int() % 256).to_byte())
  }
}
let body = Bytes::from_array(text)
let greedy = @deflate.deflate(body[:])
let long = @deflate.deflate(body[:], strategy=@deflate.Strategy::LongMatch)
assert_eq(@deflate.deflate(body[:]), @deflate.deflate(body[:], strategy=@deflate.Strategy::Greedy))
assert_eq(@deflate.inflate(long[:]), body)
assert_true(long.length() <= greedy.length())
```

`Greedy` is the default and the parse the bytes have always been: it takes the
longest match at the position the walk lands on and jumps to where it ends. A
caller who omits the strategy gets exactly that, and a test asserts the default
and the named `Greedy` are the same stream, so the output is byte for byte what
it has always been.

`LongMatch` re-walks the block a few times, each round pricing a copy at what the
block's own codes charge for it, and keeps the parse that comes out smallest. It
pays for a longer match at a farther distance instead of taking the shorter one
close by, and it considers copies the greedy walk cut off because a longer one
came first. It searches harder and writes fewer bytes on a body that repeats at
more than one period — a sentence followed by its neighbours, prose, source —
and the greedy walk is always among the candidates it measures, so on a body of
noise or of one repeated byte, where there is nothing to choose between, it
writes exactly what greedy does and no more.

The trade, measured release-build on a 120 KB body of prose:

| | Bytes | Of the greedy | Write |
|:--|--:|--:|--:|
| `Greedy` | 20,037 | — | 15.4 MB/s |
| `LongMatch` | 19,467 | 2.8% fewer | 0.66 MB/s |

Read is unchanged, because the reader is the same and the two parses decode at
the same rate; the parse is paid at write time, which is why it is opt-in and why
the default keeps the bytes it has always had. On the 1.5 MB words-and-numbers
body the throughput table is measured on, the two parses write the same size —
the greedy walk already finds the best parse there — so the strategy is invisible
on that body and earns its keep on the ones where the walk is not already right.

## Streaming

A response body arrives in chunks. A file is read four kilobytes at a time.
Neither has to be gathered first.

<!-- nocheck -->
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

Every codec here has the pair, and what each one holds between calls is the
format's own unit: one block for `deflate`, `lz4`, `zstd` and brotli's
meta-block; one chunk for `snappy` and `xz`, which state their sizes; one block
for `bzip2`, whose sort cannot begin until it is complete; and one dictionary
window for `lzma`, which has no blocks at all and carries its range coder from
token to token. Nothing holds the body, and nothing holds the compressed form of
it.

| Format | Unit held | Bound |
|:--|:--|--:|
| `deflate`, `gzip`, `zlib` | one block | 32 KiB |
| `lz4` | one block | 64 KiB |
| `snappy` | one chunk | 64 KiB |
| `zstd` | one block | 64 KiB |
| `xz` | one chunk, plus the dictionary | 1 MiB, plus the level's dictionary |
| `bzip2` | one block | 100–900 KiB, by level |
| `brotli` | one meta-block, plus the window | 1 MiB, plus the window |
| `lzma` | the dictionary | 64 KiB – 8 MiB, by level |
| `7z` | one folder | the folder's dictionary |

`zip` has a writer that hands back each member's bytes as it adds them and a
reader that walks local headers from the front, which is the only way to read an
archive that is still arriving. `7z` has the same writer — `add` hands back the
compressed bytes each entry produced — but it cannot have the same reader: a 7z
directory is written *after* the folders it describes, so nothing can be cut into
members until the last byte has arrived. Its reader takes the archive a piece at
a time, refuses a file that is not one on the first six bytes, and decodes folder
by folder when the directory shows up, keeping one folder's output rather than the
whole archive's.

For an archive on disk, `un7z_from` takes a source instead of a block of bytes:

<!-- nocheck -->
```moonbit
let members = @sevenz.un7z_from(archive_file)   // anything implementing RandomAccess
```

A `RandomAccess` is two methods — `read(offset, len)` and `size()` — so a file, a
memory mapping and a range of some larger store all fit, and a caller with neither
can wrap its own storage in a dozen lines. The signature header and the directory
are read first, because the directory is what says where the folders are; after
that each folder is read, decoded and cut into its members before the next one is
touched. The archive itself is never held: what a caller pays beyond the members
is one folder, packed and unpacked. `un7z` is this reader over an archive already
in memory, so there is one implementation of the folder logic and not two.

A message boundary is the other unit a connection has. `deflate`'s writer can end a
message without ending the stream — `flush` writes `Z_SYNC_FLUSH`, the empty stored
block every streaming compressor recognises — and the reader stops exactly there:

<!-- nocheck -->
```moonbit
let writer = @deflate.Writer::new(level=6)
for message in messages {
  for b in writer.push(message[:]) { out.push(b) }
  for b in writer.flush() { out.push(b) }        // ends with 00 00 FF FF
}
for b in writer.finish() { out.push(b) }         // the last message ends the stream

let reader = @deflate.Reader::new()
for piece in pieces {
  for b in reader.flush(piece) { out.push(b) }   // one message, window kept
}
```

What the reader keeps between messages is the same 32 KiB window, so the next
message may match against the last one — the setting a WebSocket connection calls
context takeover. `reset` on either side throws it away, and the next message
stands on its own. Both were checked against zlib: its flushed messages decode
here, ours decode there, and a message that leans on a window that was dropped is
refused rather than guessed at.

A chunk boundary may fall inside a header field, inside a Huffman code, inside a
stored block, or between a member's data and its data descriptor. The tests feed
the same body in pieces of one, two, three, five, seven, thirteen, sixty-four,
five hundred and eleven, four thousand and ninety-six, and sixty-five thousand
five hundred and thirty-six bytes, and require the same bytes out each time. The
boundaries that break a naive decoder are never the round ones.

## Archives

`gzip` compresses one thing; `zip` and `tar` hold many.

<!-- nocheck -->
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

<!-- nocheck -->
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

<!-- nocheck -->
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
and a tampered payload from the tag, both before a byte is returned.

Two details of this scheme only ever show up in somebody else's archive. The
counter block is read as a little-endian integer, not as the big-endian one the
standard counter mode uses — the two agree on the first block, so an archive of
short members round-trips either way. And a directory member carries no payload,
so an encrypted archive's directory has nothing to decrypt even though it is a
member like any other.

Both were found by `scripts/sevenzip_interop.py`, which writes all six encrypted
shapes and both volume forms here, has 7-Zip extract every one, and pins the
archives 7-Zip writes into the test suite: AES-128 and AES-256 in AE-2, a plain
archive, and a volume set. The suite reproduces the published WinZip AES vector
byte for byte as well, but that vector is thirteen bytes — one block — and the
archive of a longer member is what settles the rest.

**Volume splitting**: one archive carried in several files, `archive.z01`,
`archive.z02`, … and finally `archive.zip`. A split archive is the same bytes cut
at fixed boundaries — the central directory is still the last thing in the stream
— so rejoining the pieces in order is the archive, and every reader understands
it. `volume_names` gives the names the convention expects; the pieces are ordinary
bytes, because this package never touches a file system.

<!-- nocheck -->
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

<!-- nocheck -->
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
disk number is honoured — and it extracts byte for byte. 7-Zip takes both forms
when the pieces are named `archive.zip.001`, `.002`, … which is what
`scripts/sevenzip_interop.py` checks for every kind of body. Info-ZIP `unzip`
reads the byte-range `split` form after rejoining, but says outright that it has
no multi-part support, so it is not the tool for this one.

**A method this package does not implement** — bzip2 is 12, LZMA is 14 — is a
`Codec` away rather than an edit here:

<!-- nocheck -->
```moonbit
@zip.unzip(archive[:], codecs=mine[:])
```

## LZMA

A range coder with a binary-probability model: no bit stream to align, one table
of probabilities updated per decision, and a matched-literal trick that makes the
byte after a match much cheaper than a byte after a literal.

<!-- nocheck -->
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

<!-- nocheck -->
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

<!-- nocheck -->
```moonbit
@sevenz.sevenz(members[:], how=@sevenz.Method::Lzma2, solid=true)
@sevenz.un7z(archive[:])       // folder, substream and signature checksums verified
@sevenz.names(archive[:])      // the directory only, without touching the data
```

Both of those hold the whole thing: every member, every folder's compressed form,
and the directory, before anything comes back. The streaming pair does not.

<!-- nocheck -->
```moonbit
let w = @sevenz.Writer::new(level=6)
let mut body : Array[Byte] = []
for entry in members {
  for b in w.add(entry) {
    body.push(b)          // compressed as it arrives; write it out here
  }
}
let directory = w.finish()
let start = w.signature()  // the thirty-two bytes that go in front
```

The order is the format's, not a choice. A 7z archive opens with a thirty-two byte
header that says where the directory sits — which is the length of the packed data,
a number nobody has until the last folder is written — so those bytes are produced
last and placed first. `signature` before `finish` aborts rather than returning
something plausible.

<!-- nocheck -->
```moonbit
let r = @sevenz.Reader::new(limit=1 << 26)
for piece in pieces {
  r.push(piece[:])        // the signature is checked on the first six bytes
}
let members = r.finish()
```

A reader cannot do better than that here, and it is worth saying why: the directory
comes *after* the folders it describes, so no member's boundary is known until the
last byte has arrived. What the reader streams is the input and the decoding — it
keeps one folder's output at a time rather than the whole archive's, and it refuses
a file that is not a 7z archive on its first six bytes rather than after a
gigabyte of them. A writer, which *does* know the order in advance, streams
properly: an entry is compressed as it arrives and its bytes leave immediately.

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

<!-- nocheck -->
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

<!-- nocheck -->
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

**The writer is LZ77 with brotli's three models bolted on.** A hash chain and
Huffman codes from exact counts at every position; from quality 9 up, literal
contexts, block types for the command and literal streams, and the static
dictionary. `quality` (0 to 11, default 9) is how hard it looks. Up to 8 that is
the chain depth and a lazy step, which is the whole of a greedy parse, and 0 is
the single-candidate "fast" search LZ4 ships. From 10 the parse is chosen rather
than taken: a walk over the block keeps the cheapest price of reaching every
position, priced from the codes the round before produced, and every round's
result is encoded to see which is genuinely smaller. On the body in the table below — 184,000 bytes of
repetitive English — quality 9 reaches 518 bytes, ahead of gzip at 1,983 and zstd
at 3,042, because one long match is worth more than everything the fancier models
add.


- **Literal contexts.** The writer picks a context mode — `UTF8` for text, `LSB6`
  for binary — counts every literal in one of 64 sub-alphabets keyed by the two
  bytes before it, and then groups those sub-alphabets into at most six codes. The
  grouping is a recursive bisection: each round splits the group whose split pays
  best, and stops when no split pays or the cap is reached. The routing table that
  says which context uses which code is sent with the stream, so a body whose
  contexts look alike comes out with one code and one bit of map.
- **Split streams.** The command stream may be cut in two, and so may the literal
  stream, each half carrying its own prefix code and — for literals — its own
  context map. Where each cut falls is searched; both are declined when the extra
  code does not pay.
- **The static dictionary.** Words the format already knows are coded as a
  dictionary reference — a distance past the window that names `(transform, word)`
  — instead of their letters. The writer indexes the 13,504 words by their first
  four bytes and probes each position twice: once as spelled, once with the first
  letter lowercased, so a sentence-initial `Time` costs the same code as `time`.
  It then reaches 103 of the 121 transforms. With no prefix the word starts at the
  position being searched, so that index finds it and the work is comparing the
  suffix after it; with a prefix the text starts with those bytes and the word
  starts just past them, so the same index works one probe further in. That covers
  `word + " "`, `word + "."`, `" " + word`, `" the " + word + " of "` and the
  capitalised and shouted spellings of each. Eight are out of reach because they
  drop the word's *opening* bytes, which are exactly what the text does not
  contain. Ten more — the ones that drop the word's tail — are reachable and
  declined: a truncated word covers less text for the same far distance, and on
  this file they cost 260 bytes at every minimum length tried. An affix is not part
  of the copy length either: the command carries the *word's* length, which selects
  the bucket, and the transform decides how much comes out, so `time` with the
  space-suffix transform is a copy of four bytes that produces five.

Every one of those choices **prices what it is choosing instead of estimating it**:
the candidate code is written to a throwaway bit stream and counted. An estimate of
"so many bits per used symbol" is wrong by enough to accept splits that then come
out larger than the stream they were meant to shrink, which is exactly what
happened here first — a body of short repeated phrases grew by six bytes at
quality 11. With exact pricing, turning any of them on can no longer cost bytes,
and a test pins that.

The literal cut is the one that varies most with the body, and it is measured in
both directions. On this repository's own documentation — README, homepage and guide, about
111 KB, which is what the pages you are reading add up to — quality 9 gives
29.2 KB against the reference encoder's 29.1 KB on the same bytes: level, which is
where a writer and its reference meet when the models match. Quality 11 gives
26.7 KB against the reference's 26.4 KB, and the same body through the search this
package had before came out at 27.6 KB, so the parse change is worth 3.3%.

Three things were added, and one measurement is worth more than the three
descriptions. **The insert run is a state**: the search keeps the eight cheapest
positions a command could have ended at, ordered by what they cost beyond coding
the bytes in between as literals, and tries copies from the five cheapest, because
a command's insert length is coded jointly with its copy length. **The ring of
recent distances is in the search**: all sixteen short codes are tried at every
position against the ring the cheapest path there would have left behind, because
those distances are not in the match list — the chain was built before the parse
decided anything. **The candidate list is thirty-two deep** rather than six.

Of the three, keeping the start positions is where the bytes are: a search with one
start instead of five writes 1.1% more on the same body. The ring is close to a
wash in bytes — 0.36% better on prose, 0.2% worse on a body of words and numbers —
and the reason is that this writer already had a pass that rewrites each copy to a
cheap distance when the bytes allow it (`cheapen`), which is the job the reference
puts in its search because it has no such pass. What the ring buys here is the
price model: with a cheap distance actually reachable, a copy can be charged the
symbol it takes instead of what a repeat costs, and the search stops having to be
lied to. The deeper candidate list stops paying past a dozen on every body
measured; thirty-two is the reference's order of magnitude, not a measured win.

Every new form is checked against the reference decoder, not just this one: a
quality-11 stream over a 101 KB body, whose header declares two block types and a
literal context map where quality 9 declares one of each, decodes through
`brotli 1.2.0` to the same bytes — including the dictionary references, which the
reference reader resolves against its own copy of the blob, and the copies whose
transform produces more bytes than the command's copy length. Text, binary and
two-alphabet bodies were checked the same way, because each takes a different path
through the writer.

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
| brotli | 518 | 0.3% |
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
`src/examples/throughput` — the median of ten runs after a warm-up, over a 1.5 MB
body of words and numbers that compresses 3.4 to 1 — on two machines: the runner
the project's CI measures on, and a laptop. A rate moves by a third between runs on
either, so read them as orders of magnitude, and compare the columns of one machine
rather than the two machines against each other.

| Codec | Write, CI | Read, CI | Write, laptop | Read, laptop |
|:--|--:|--:|--:|--:|
| `deflate` | 18 | 190 | 8.5 | 80 |
| `gzip` | 17 | 129 | 9.0 | 63 |
| `zlib` | 18 | 171 | 8.6 | 65 |
| `zstd` | 29 | 83 | 8.7 | 24 |
| `brotli` (quality 9) | 1.4 | 103 | 0.3 | 27 |

On the CI host the same body through C zlib — `zlib.compress(_, 6)` and
`zlib.decompress` from Python, which `scripts/throughput_reference.py` reproduces
and the same job runs — writes at 20 MB/s and reads at **349**. The deflate writer
is therefore within a tenth of zlib's own write rate, and the reader is at 190, a
little over half of it.

That is what the reader was rebuilt for. It read 143 to 153 on the same host before
this batch, and the cost was per symbol rather than per byte:

| | Before | After |
|:--|--:|--:|
| `deflate` read, CI | 150 | 190 |
| the bit accumulator | 32 bits, a byte at a time | 64 bits, eight at a time |
| codes longer than the look-ahead | walked a bit at a time | one more table |
| table reads between symbols | bounds-checked, from fields | unchecked, from locals |
| a stored block's payload | one byte at a time | eight |

What is left of the gap is the parse, not the reader. `deflate` prefers many short
matches to one long one — 206,000 of the 208,000 tokens in this body are matches
averaging seven bytes — so a decoder is asked to do more per byte here than a parse
that folds those seven bytes into one token would ask. That is a property of the
writer, and its bytes are pinned by tests, so this batch left it alone.

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

---
name: moonzip
description: Compression and archives for MoonBit — DEFLATE, gzip, zlib, zip, 7z, tar, lz4, snappy, lzma, xz, bzip2, zstd and brotli, one package each, one-shot or a piece at a time. Use when a task needs to compress or decompress bytes, read or write an archive, wrap a body in gzip or zlib, or send deflate-compressed messages such as WebSocket permessage-deflate.
---

# moonzip

Thirteen formats, one package per format: importing `moonzip/gzip` does not bring
`snappy` with it. Every codec has a one-shot pair and a streaming pair, every
reader takes a `limit` against a decompression bomb, and every writer is
reproducible — the same input gives the same bytes.

## Install

```bash
moon add moonbitstack/moonzip
```

```moonbit
import {
  "moonbitstack/moonzip/gzip",
  "moonbitstack/moonzip/zip",
}
```

## Compress and decompress one buffer

`gzip`, `zlib` and `deflate` are the same codec in three containers; pick the one
the other end expects. The writer takes an optional `strategy`: `Greedy` (the
default, byte for byte what it has always written) or `LongMatch`, a harder parse
that writes fewer bytes on a body that repeats at more than one period.

```moonbit
let body = @utf8.encode("the quick brown fox jumps over the lazy dog. ")
let packed = @gzip.gzip(body[:])                  // RFC 1952, with a CRC-32
let back = @gzip.gunzip(packed[:])                // raises if the checksum disagrees
assert_eq(back, body)
let raw = @deflate.deflate(body[:], level=9)      // RFC 1951, no container
assert_eq(@deflate.inflate(raw[:]), body)
```

Reading untrusted input: pass `limit` and the reader stops before it allocates a
gigabyte.

<!-- nocheck -->
```moonbit
let back = @deflate.inflate(raw[:], limit=4 << 20) catch {
  @moonzip.TooBig(_) => bail_out()
  e => raise e
}
```

## Compress a body as it arrives

`Writer::push` takes whatever has arrived and hands back whatever is ready;
`finish` writes the last block and the trailer. The reader is the mirror.

<!-- nocheck -->
```moonbit
let writer = @gzip.Writer::new(level=6)
for part in parts {
  for b in writer.push(part) {
    out.push(b)
  }
}
for b in writer.finish() {
  out.push(b)
}
```

Between calls the writer holds one block and the 32 KiB window, never the body.
For message-oriented protocols, `@deflate.Writer::flush` ends a message with
`Z_SYNC_FLUSH` and keeps the window, and `reset` throws the window away — the two
settings a WebSocket connection negotiates as context takeover.

<!-- nocheck -->
```moonbit
let writer = @deflate.Writer::new(level=6)
for b in writer.push(message[:]) {
  out.push(b)
}
for b in writer.flush() {
  out.push(b)                                     // ends with 00 00 FF FF
}
let reader = @deflate.Reader::new()
let text = reader.flush(message_bytes)            // one message, window kept
```

## Read and write archives

`zip` and `tar` hold many files; `sevenz` holds many files with a directory
written after them.

<!-- nocheck -->
```moonbit
let archive = @zip.zip([@zip.Entry::new("readme.txt", body)][:])
let members = @zip.unzip(archive[:])
let names = @zip.names(archive[:])                // the directory, nothing else
```

A 7z archive is read through a random-access source, so a file never has to fit
in memory: the directory is read first, then one folder at a time.

<!-- nocheck -->
```moonbit
let members = @sevenz.un7z_from(file)             // `file` implements RandomAccess
```

## Rules that are easy to get wrong

- `unzip`, `un7z`, `untar`, `gunzip` and their kin **raise `@moonzip.Refused`**;
  the one-shot writers do not raise.
- `limit` counts the whole output, and it is checked as the bytes are produced,
  not after.
- A reader that is given a directory must be told how to read entries it does not
  implement: `@zip.unzip(data, codecs=[...])` takes any `@zip.Codec`.
- `Writer::finish` may be called once; a stream that is not finished is truncated.
- The streaming reader hands back what it decoded so far, which may be empty for
  several pushes: a symbol can straddle a chunk boundary.

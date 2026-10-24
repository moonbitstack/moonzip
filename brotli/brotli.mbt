// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Brotli, RFC 7932: https://datatracker.ietf.org/doc/html/rfc7932
///
/// A dictionary, a context model and a prefix coder, in that order of difficulty
/// for a reader. DEFLATE's idea — find repeats, code the leftovers — is the same;
/// what brotli adds is three things that each cost a table:
///
/// * **Block types.** Each of the three symbol streams (literals, commands,
///   distances) can switch between up to 256 sets of codes, with two recently
///   used types addressable in three bits. Text and its embedded numbers want
///   different tables, and this is how a file gets both.
/// * **Contexts.** A literal is coded with one of 64 sub-alphabets chosen by the
///   two bytes before it. That is why brotli beats DEFLATE on source code and
///   JSON by more than a few per cent.
/// * **A static dictionary.** 13,504 common words in several languages, reachable
///   by a distance larger than the window, and 121 transforms over them. A word
///   the encoder recognises costs a distance code instead of its letters.
///
/// The reader here is complete: all four context modes, block switching, the
/// dictionary and every transform. The writer is a plain LZ77 encoder — see
/// `brotli` below for exactly what that costs and why.
///
/// ```moonbit
/// let packed = @brotli.brotli(@utf8.encode("the quick brown fox"))
/// let back = @brotli.unbrotli(packed)
/// ```

///|
/// Un-brotli a complete stream.
pub fn unbrotli(
  data : BytesView,
  limit? : Int32,
) -> Bytes raise @moonzip.Refused {
  let bound = match limit {
    Some(n) => if n < 0 { 0 } else { n }
    None => 0x7FFFFFFF
  }
  let dec = Dec::new(data, bound)
  dec.header()
  let mut more = true
  while more {
    more = dec.metablock()
  }
  Bytes::from_array(dec.out)
}

///|
/// Brotli, RFC 7932.
///
/// The writer is deliberately a plain one: greedy LZ77 over a single hash table,
/// one meta-block per megabyte, one block type per stream, and Huffman codes
/// computed from the exact symbol counts. What it does **not** do is the half of
/// brotli that earns the format its ratio: literal context modelling, block
/// splitting, the static dictionary, and the exhaustive parse at quality 11.
///
/// That is a choice, not a gap. Those four are search problems over the same
/// format the reader already implements, and a writer that used them would need
/// the reference encoder's 30,000 lines to be worth the difference. This one is
/// correct, readable by every brotli implementation, and roughly comparable to
/// gzip on text.
///
/// `window` is the log of the window size, 10 to 24: how far back a copy may
/// reach. Larger windows find more matches and cost nothing but memory while
/// writing, since the reader keeps whatever it needs.
pub fn brotli(data : BytesView, window~ : Int32 = 22) -> Bytes {
  compress(data, window, 1 << 24)
}

///|
/// The writer proper, with the meta-block size exposed.
///
/// Sixteen megabytes is the format's limit and the only size `brotli` uses; the
/// parameter exists so the tests can force a dozen meta-blocks out of a small
/// body, which is the only way to exercise the "another block follows" path
/// without compressing a sixteen-megabyte file.
fn compress(data : BytesView, window : Int32, block : Int32) -> Bytes {
  let size = if window < 10 { 10 } else if window > 24 { 24 } else { window }
  let w = Writer::new()
  write_window(w, size)
  // One hash table and one chain for the whole stream: matches may reach back
  // into an earlier meta-block, and forgetting that at every megabyte is a loss
  // that shows up on exactly the periodic files a compressor is for.
  let table = FixedArray::make(1 << 16, -1)
  let chain = FixedArray::make(chain_size(), -1)
  let mut at = 0
  let total = data.length()
  while at < total {
    let span = if total - at > block { block } else { total - at }
    write_block(w, data, at, span, (1 << size) - 16, table, chain)
    at += span
  }
  // The stream ends with a meta-block that is both last and empty: one bit for
  // each, and nothing after them.
  w.put(1, 1)
  w.put(1, 1)
  w.finish()
}

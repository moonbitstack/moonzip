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
/// The writer does all of what earns the format its ratio: literal context
/// modelling, block types for the literal and command streams, the static
/// dictionary, and short distance codes. At quality 9 — the default — it is level
/// with the reference encoder on this repository's own documentation, and
/// somewhat ahead of it below that.
///
/// `window` is the log of the window size, 10 to 24: how far back a copy may
/// reach. Larger windows find more matches and cost nothing but memory while
/// writing, since the reader keeps whatever it needs.
///
/// `quality` is 0 to 11 and is how hard the writer looks, not which features it
/// uses. Up to 8 it sets the number of hash-chain candidates walked and whether a
/// lazy step is taken, which is the whole of a greedy parse. From 10 the parse is
/// chosen rather than taken: an optimal walk over the block keeps the cheapest
/// price of reaching every position, prices come from the codes the previous
/// round produced, and each round's result is encoded to see which is genuinely
/// smaller. That is four times the work of quality 9 and, on text, four and a
/// half per cent off the output.
///
/// A higher quality never produces more bytes and always takes longer.
pub fn brotli(
  data : BytesView,
  window~ : Int32 = 22,
  quality~ : Int32 = 9,
) -> Bytes {
  let (depth, lazymatch, split, contexts, dictionary, optimal) = effort(quality)
  compress(
    data,
    window,
    1 << 24,
    depth~,
    lazymatch~,
    split~,
    contexts~,
    dictionary~,
    optimal~,
  )
}

///|
/// The search effort a quality names: the hash-chain depth and whether a lazy
/// step is taken. Quality 9 is the value the one-shot call has always used, so
/// the default output is unchanged; 0 and 11 are the fast and exhaustive ends.
fn effort(quality : Int32) -> (Int32, Bool, Bool, Bool, Bool, Bool) {
  let q = if quality < 0 { 0 } else if quality > 11 { 11 } else { quality }
  match q {
    0 => (1, false, false, false, false, false)
    1 => (2, false, false, false, false, false)
    2 => (4, true, false, false, false, false)
    3 => (8, true, false, false, false, false)
    4 => (16, true, false, false, false, false)
    5 => (32, true, false, false, false, false)
    6 => (64, true, false, false, false, false)
    7 => (128, true, false, false, false, false)
    8 => (192, true, false, false, false, false)
    // Nine is the default, and it models: literal contexts, split streams and the
    // dictionary are what brotli is for, and a default that leaves them off is a
    // default that loses to gzip on the one corpus every reader has — prose.
    9 => (256, true, true, true, true, false)
    10 => (512, true, true, true, true, true)
    _ => (1024, true, true, true, true, true)
  }
}

///|
/// The writer proper, with the meta-block size exposed.
///
/// Sixteen megabytes is the format's limit and the only size `brotli` uses; the
/// parameter exists so the tests can force a dozen meta-blocks out of a small
/// body, which is the only way to exercise the "another block follows" path
/// without compressing a sixteen-megabyte file.
fn compress(
  data : BytesView,
  window : Int32,
  block : Int32,
  depth~ : Int32 = 256,
  lazymatch~ : Bool = true,
  split~ : Bool = false,
  contexts~ : Bool = false,
  dictionary~ : Bool = false,
  optimal~ : Bool = false,
) -> Bytes {
  let size = if window < 10 { 10 } else if window > 24 { 24 } else { window }
  let w = BitWriter::new()
  write_window(w, size)
  // One hash table and one chain for the whole stream: matches may reach back
  // into an earlier meta-block, and forgetting that at every megabyte is a loss
  // that shows up on exactly the periodic files a compressor is for.
  let table = FixedArray::make(1 << 16, -1)
  let chain = FixedArray::make(chain_size(), -1)
  // The optimal search keeps a few dozen bytes of state per input byte, so its
  // blocks are smaller than the format's sixteen megabytes. Splitting there costs
  // one set of code descriptions per megabyte, which is what the reference encoder
  // pays as well; the alternative is a caller handing in two megabytes and silently
  // getting the greedy parse at a quality that promises otherwise.
  let chunk = if optimal && block > OPTIMAL_LIMIT {
    OPTIMAL_LIMIT
  } else {
    block
  }
  let mut at = 0
  let total = data.length()
  while at < total {
    let span = if total - at > chunk { chunk } else { total - at }
    write_block(
      w,
      data,
      at,
      span,
      (1 << size) - 16,
      table,
      chain,
      depth,
      lazymatch,
      split,
      contexts,
      dictionary,
      optimal~,
    )
    at += span
  }
  // The stream ends with a meta-block that is both last and empty: one bit for
  // each, and nothing after them.
  w.put(1, 1)
  w.put(1, 1)
  w.finish()
}

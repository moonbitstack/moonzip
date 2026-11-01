// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The fixed table names every symbol the format gives it a code for, and the
/// look-ahead consumes exactly the width it reports.
///
/// The table is what the reader now uses for the common case, and an entry that
/// names the right symbol but the wrong width passes a one-symbol test and fails
/// on the second symbol in the stream — which is why this decodes all 288 of them
/// back to back. The fixed code is also the one table that is not in the stream,
/// so a bug here would show up on every short input rather than on a rare file.
test "the fixed table names every symbol it has a code for" {
  let bw = BitWriter::new()
  for sym in 0..<288 {
    let (code, width) = fixed_code(sym)
    bw.huff(code, width)
  }
  let stream = bw.finish()
  let br = BitReader::new()
  br.push(stream[:])
  for sym in 0..<288 {
    assert_eq(fixed_litlen.sym(br), sym)
  }
}

///|
/// A code that reaches past the look-ahead decodes through the slow path.
///
/// A Huffman code cannot consist only of long symbols — the widths have to sum to
/// one, so a 15-bit symbol has to be paid for by short ones. This is the shape
/// that does: one symbol at each width from one to fourteen, and the last two at
/// fifteen. The last symbol is therefore longer than the nine bits the table
/// covers, so its lookup misses and the walk runs, while the short symbols prove
/// the two paths interleave without either one stealing bits from the other.
test "a code that reaches past the look-ahead decodes through the slow path" {
  let widths = FixedArray::make(16, 0)
  for i in 0..<14 {
    widths[i] = i + 1
  }
  widths[14] = 15
  widths[15] = 15
  let code = Huffman::of(widths, 16)
  let codes = canonical(widths, 16, 15)
  let bw = BitWriter::new()
  for _ in 0..<3 {
    for sym in 0..<16 {
      bw.huff(codes[sym], widths[sym])
    }
  }
  let stream = bw.finish()
  let br = BitReader::new()
  br.push(stream[:])
  for _ in 0..<3 {
    for sym in 0..<16 {
      assert_eq(code.sym(br), sym)
    }
  }
}

///|
/// The reader says how far it got, and a symbol read from an exhausted buffer is
/// the sentinel rather than a symbol.
///
/// `-1` is what every caller in the loop tests for, so it is worth pinning that
/// the reader produces it at the exact point the input runs out — not earlier, and
/// not as some other negative number.
test "an exhausted buffer answers with the sentinel" {
  let br = BitReader::new()
  assert_eq(br.take(1), -1)
  br.push(b"\xff"[:])
  assert_eq(br.take(8), 0xFF)
  assert_eq(br.take(1), -1)
  assert_eq(br.remaining(), 0)
}

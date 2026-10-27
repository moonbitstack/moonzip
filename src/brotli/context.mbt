// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Literal context, four modes over the same 2,048-byte table.
///
/// Brotli does not encode a literal on its frequency alone: it picks one of up
/// to 64 sub-alphabets from the two bytes before it. The modes are:
///
/// * `LSB6` — the low six bits of the previous byte. Cheap, and good for binary.
/// * `MSB6` — the high six bits. Good for structured binary.
/// * `UTF8` — a hand-written model of where in a UTF-8 character we are and what
///   kind of character the previous one was. The one that matters for text.
/// * `SIGNED` — as `UTF8`, but treating bytes as signed deltas, which is what
///   binary numeric arrays want.
///
/// The definition is `table[mode][previous] | table[mode][256 + before that]`,
/// two independent lookups OR-ed together, which is why the table is four
/// quadrants of 512 entries.
fn context_id(mode : Int32, previous : Int32, before_that : Int32) -> Int32 {
  let base = (mode & 3) * 512
  context_lut[base + previous] | context_lut[base + 256 + before_that]
}

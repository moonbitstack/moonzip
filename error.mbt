// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Why a compressed stream could not be read.
///
/// The offset is where the reader was when it gave up, in bytes from the start
/// of the stream — enough to find the damage in a file, which "corrupt data" is
/// not.
pub(all) suberror Broken {
  /// The stream ends in the middle of something.
  Truncated(at~ : Int)
  /// A header field that is not what the format allows: a block type DEFLATE
  /// does not define, a compression method gzip does not name, a reserved flag.
  Header(at~ : Int, what~ : String)
  /// A Huffman code no symbol is assigned to, or a code table that does not add
  /// up.
  Code(at~ : Int)
  /// A back-reference that reaches before the start of the output.
  Distance(at~ : Int)
  /// The trailing checksum does not match what was decompressed.
  Checksum(want~ : UInt, got~ : UInt)
  /// The trailing length does not match what was decompressed.
  Length(want~ : UInt, got~ : Int)
  /// The output passed the bound the caller set. A compressed stream says
  /// nothing about how far it expands, so a reader handling input from
  /// elsewhere says how much it is prepared to hold.
  TooBig(limit~ : Int)
} derive(Eq, Debug)

///|
pub extend Broken with Eq::{equal, not_equal}

///|
pub extend Broken with Debug::{to_repr}

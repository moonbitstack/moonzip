// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Why a compressed stream could not be read.
///
/// The offset is where the reader was when it gave up, in bytes from the start
/// of the stream — enough to find the damage in a file, which "corrupt data" is
/// not.
pub(all) suberror Refused {
  /// The stream ends in the middle of something.
  Truncated(at~ : Int32)
  /// A header field that is not what the format allows: a block type DEFLATE
  /// does not define, a compression method gzip does not name, a reserved flag.
  Header(at~ : Int32, what~ : String)
  /// A Huffman code no symbol is assigned to, or a code table that does not add
  /// up.
  Code(at~ : Int32)
  /// A back-reference that reaches before the start of the output.
  Distance(at~ : Int32)
  /// The trailing checksum does not match what was decompressed.
  Checksum(want~ : UInt32, got~ : UInt32)
  /// The trailing length does not match what was decompressed.
  Length(want~ : UInt32, got~ : Int32)
  /// The output passed the bound the caller set. A compressed stream says
  /// nothing about how far it expands, so a reader handling input from
  /// elsewhere says how much it is prepared to hold.
  TooBig(limit~ : Int32)
} derive(Eq, Debug)

///|
pub extend Refused with Eq::{equal, not_equal}

///|
pub extend Refused with Debug::{to_repr}

///|
pub extend Refused with Show::{to_string, output}

///|
/// A sentence for a log line or an error page.
///
/// The offset travels with the words: "where" is half of "why" when the only
/// thing you have is a stream that used to work.
pub impl Show for Refused with fn output(self, logger) {
  match self {
    Truncated(at~) => logger.write_string("stream ends early at byte \{at}")
    Header(at~, what~) =>
      logger.write_string("bad header at byte \{at}: \{what}")
    Code(at~) => logger.write_string("bad code at byte \{at}")
    Distance(at~) =>
      logger.write_string("back-reference before the start at byte \{at}")
    Checksum(want~, got~) =>
      logger.write_string("checksum \{got} does not match \{want}")
    Length(want~, got~) =>
      logger.write_string("length \{got} does not match the header's \{want}")
    TooBig(limit~) =>
      logger.write_string("output passed its \{limit}-byte bound")
  }
}

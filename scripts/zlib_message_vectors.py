#!/usr/bin/env python3
"""Print what zlib writes when it flushes a message, for the reader's test.

    python3 scripts/zlib_message_vectors.py

Two messages compressed by one `compressobj` in raw DEFLATE at level 6, with
`Z_SYNC_FLUSH` after each, so the second message refers back into the first. The
test that reads them is `src/deflate/deflate_test.mbt`; the point of the pair is
that the second one cannot be decoded without the first, which is what makes it a
test of the window and not of the decoder.

The bytes go in the test as they come out of here. zlib's output is pinned for the
same reason a signature is: a reader that only ever sees what this library writes
is a reader nobody has tried.
"""

import zlib

MESSAGES = [
    b"hello hello hello, the message that keeps its context. ",
    b"and a second one that may reach back into it. ",
]


def main():
    compressor = zlib.compressobj(6, zlib.DEFLATED, -15)
    for message in MESSAGES:
        piece = compressor.compress(message) + compressor.flush(zlib.Z_SYNC_FLUSH)
        print(piece.hex())


if __name__ == "__main__":
    main()

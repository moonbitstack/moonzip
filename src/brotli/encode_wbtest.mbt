// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A body with many commands and a little variety, so the two halves of the
/// command stream can choose different codes.
fn split_body() -> Bytes {
  let out : Array[Byte] = []
  for i in 0..<3000 {
    for b in b"alpha beta gamma delta " {
      out.push(b)
    }
    out.push((0x30 + i / 100 % 10).to_byte())
    out.push((0x30 + i / 10 % 10).to_byte())
    out.push((0x30 + i % 10).to_byte())
    out.push(b' ')
  }
  Bytes::from_array(out)
}

///|
/// The search puts the cut where the stream changes kind. Two hundred commands of
/// one symbol followed by two hundred of another has a seam at 200; a single code
/// spends four hundred bits on it, two codes spend ten.
test "the split search finds the seam" {
  let codes = FixedArray::make(400, 0)
  for i in 0..<400 {
    codes[i] = if i < 200 { 5 } else { 300 }
  }
  let cut = best_cut(codes, 400)
  // The search samples a grid rather than every index, so the seam is approached
  // rather than hit exactly.
  assert_true(cut > 190 && cut < 210)
}

///|
/// A stream that is one symbol throughout has nothing to gain from a second code,
/// and the description of that code is a real cost. The search must decline.
test "a uniform command stream is not split" {
  let codes = FixedArray::make(300, 7)
  assert_eq(best_cut(codes, 300), 300)
}

///|
/// Both paths write a stream that reads back, whatever the search decides.
test "the split path still reads back" {
  let body = split_body()
  let flat = compress(body[:], 22, 1 << 24)
  let split = compress(body[:], 22, 1 << 24, split=true)
  assert_eq(unbrotli(flat[:]), body)
  assert_eq(unbrotli(split[:]), body)
}

///|
/// A body too small to hold two commands is not split, and must still read back —
/// the guard that keeps a one-command block from asking for a second type.
test "a tiny block is not split and still reads back" {
  let body = b"hi"
  let flat = compress(body[:], 22, 1 << 24)
  let split = compress(body[:], 22, 1 << 24, split=true)
  assert_eq(flat, split)
  assert_eq(unbrotli(split[:]), body)
}

///|
/// Identical contexts are one code, not sixty-four. Everything else would be
/// paying for a map that routes every context to the same place.
test "contexts that look alike share one code" {
  let hist = FixedArray::make(64 * 256, 0)
  for c in 0..<64 {
    hist[c * 256 + 65] = 100
  }
  let (groups, _) = group_contexts(hist)
  assert_eq(groups, 1)
}

///|
/// Two families of contexts that spell different letters want different codes,
/// and the map has to send them to different ones.
test "two context families get two codes" {
  let hist = FixedArray::make(64 * 256, 0)
  for c in 0..<32 {
    hist[c * 256 + 65] = 100
  }
  for c in 32..<64 {
    hist[c * 256 + 66] = 100
  }
  let (groups, map) = group_contexts(hist)
  assert_true(groups >= 2)
  assert_true(map[0] != map[63])
}

///|
/// A body with English letter statistics and no long repeats: every letter is
/// chosen from a small table of plausible followers, so the text has the local
/// structure a context model is for while the match finder has little to take.
fn bigram_body() -> Bytes {
  let follows : Array[Bytes] = [
    b"ntrl", b"ear", b"hto", b"eio", b"rnsa", b"orat", b"ehir", b"eai", b"tns", b"uoa",
    b"eian", b"eal", b"eao", b"tdo", b"nurf", b"ero", b"u", b"eato", b"teah", b"hieo",
    b"rntl", b"eio", b"ahei", b"ptr", b"o e", b"e",
  ]
  let out : Array[Byte] = []
  for i in 0..<900 {
    let mut state : UInt32 = 20261101U + i.reinterpret_as_uint()
    let mut letter = 0
    for _ in 0..<70 {
      state = state * 1103515245U + 12345U
      let pool = follows[letter]
      letter = pool[(state >> 16).reinterpret_as_int() % pool.length()].to_int() -
        0x61
      out.push((0x61 + letter).to_byte())
    }
    out.push(b' ')
  }
  Bytes::from_array(out)
}

///|
/// Modelling literals by context changes the stream and shrinks it, and both
/// forms read back.
test "literal contexts change the stream and shrink it" {
  let body = bigram_body()
  let flat = compress(body[:], 22, 1 << 24)
  let modelled = compress(body[:], 22, 1 << 24, contexts=true)
  assert_not_eq(flat, modelled)
  assert_eq(unbrotli(flat[:]), body)
  assert_eq(unbrotli(modelled[:]), body)
  assert_true(modelled.length() < flat.length())
}

///|
/// The search is exact about what a second code costs, so asking for context
/// modelling can never produce a larger stream than declining it. That is the
/// property worth pinning: an estimate lenient enough to accept a losing split
/// shows up here as a body that got bigger.
test "context modelling never costs bytes" {
  let bodies : Array[Bytes] = [
    bigram_body(),
    Bytes::from_array(Array::make(5000, b'x')),
    Bytes::from_array(Array::make(3000, b'a')),
  ]
  for body in bodies {
    let flat = compress(body[:], 22, 1 << 24)
    let modelled = compress(body[:], 22, 1 << 24, contexts=true)
    assert_true(modelled.length() <= flat.length())
    assert_eq(unbrotli(modelled[:]), body)
  }
}

///|
/// The affix table holds every transform the index can address: plain, capitalised,
/// shouted, prefixed or not, and the nine that drop the word's tail. What it must
/// not hold is the ones that drop the word's *head*, because there the bytes the
/// index is keyed on are the bytes the text does not contain.
test "the affix table holds the searchable transforms" {
  let affixes = affix_table()
  assert_eq(affixes.length(), 103)
  let mut prefixed = 0
  let mut shouted = 0
  let mut plain_capital = false
  let mut word_and_space = false
  for affix in affixes {
    let kind = transforms[affix.id * 3 + 1]
    assert_true(kind != 12 && kind != 20)
    assert_true(kind <= 11)
    if affix.prefix.length() > 0 {
      prefixed += 1
    }
    if affix.mode == CASE_ALL {
      shouted += 1
    }
    if affix.mode == CASE_FIRST &&
      affix.prefix.length() == 0 &&
      affix.suffix.length() == 0 {
      plain_capital = true
    }
    if affix.mode == CASE_PLAIN &&
      affix.prefix.length() == 0 &&
      affix.suffix.length() == 1 &&
      affix.suffix[0] == b' ' {
      word_and_space = true
    }
  }
  assert_eq(prefixed, 35)
  assert_eq(shouted, 19)
  assert_true(plain_capital)
  assert_true(word_and_space)
}

///|
/// A body of common words is smaller with the dictionary than without it, and
/// both forms read back. These words are all in the blob and none of them repeat
/// often enough for a back-reference to cover them, which is the case the
/// dictionary exists for.
test "dictionary words shrink the stream and still read back" {
  let parts : Array[Bytes] = [
    b"the ", b"quick ", b"brown ", b"fox ", b"jumps ", b"over ", b"lazy ", b"dog ",
    b"Time ", b"people ", b"world ", b"work ", b"number ", b"water ", b"light ",
    b"house ", b"music ", b"story ", b"school ", b"market ",
  ]
  let out : Array[Byte] = []
  for i in 0..<20 {
    for b in parts[i % parts.length()] {
      out.push(b)
    }
    for ch in i.to_string() {
      out.push((ch.to_int() & 0xFF).to_byte())
    }
    out.push(b' ')
  }
  let body = Bytes::from_array(out)
  let plain = compress(body[:], 22, 1 << 24, depth=1024)
  let words = compress(body[:], 22, 1 << 24, depth=1024, dictionary=true)
  assert_eq(unbrotli(plain[:]), body)
  assert_eq(unbrotli(words[:]), body)
  assert_true(words.length() < plain.length())
}

///|
/// A sentence-initial capital is the same word: `Time` has to match the entry for
/// `time`, which is what the second hash probe is for.
test "a capitalised word finds its lowercase entry" {
  let out : Array[Byte] = []
  for round in 0..<40 {
    for b in b"time people world work number water light house music story " {
      out.push(b)
    }
    out.push((0x30 + round % 10).to_byte())
    out.push(b' ')
  }
  let body = Bytes::from_array(out)
  let words = compress(body[:], 22, 1 << 24, depth=1024, dictionary=true)
  assert_eq(unbrotli(words[:]), body)
}

///|
/// Two halves of the same contexts but different alphabets: bytes whose low six
/// bits agree, so the context model cannot tell them apart, and only a second
/// literal block type can.
///
/// The cut is worth a lot here — each half spends four bits a byte once it has its
/// own code where the shared code needs five — and that is the point of the test:
/// a refactor that quietly stopped cutting the literal stream would leave the two
/// sizes within a fraction of a percent, as the command split alone is.
fn two_alphabets() -> Bytes {
  let out : Array[Byte] = []
  let mut state : UInt32 = 2463534242U
  for i in 0..<8000 {
    state = state * 1103515245U + 12345U
    let low = ((state >> 16) & 0xF).reinterpret_as_int()
    if i < 4000 {
      out.push(low.to_byte())
    } else {
      out.push((0x40 + low).to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
test "the literal stream is cut when its halves differ" {
  let body = two_alphabets()
  let flat = compress(body[:], 22, 1 << 24, contexts=true)
  let cut = compress(body[:], 22, 1 << 24, contexts=true, split=true)
  assert_eq(unbrotli(flat[:]), body)
  assert_eq(unbrotli(cut[:]), body)
  // Ten percent is far beyond what the command split alone reaches on this body.
  assert_true(cut.length() * 10 < flat.length() * 9)
}

///|
/// On a body that is one kind of text throughout, the cut is declined: the second
/// block type would cost two context maps and a second set of codes for nothing.
test "the literal stream is left whole when cutting does not pay" {
  let words : Array[Bytes] = [
    b"alpha", b"beta", b"gamma", b"delta", b"epsilon", b"zeta", b"eta", b"theta",
  ]
  let out : Array[Byte] = []
  let mut state : UInt32 = 987654321U
  for i in 0..<3000 {
    state = state * 1103515245U + 12345U
    for b in words[(state >> 16).reinterpret_as_int() % 8] {
      out.push(b)
    }
    out.push(b' ')
    if i % 9 == 8 {
      out.push(b'\n')
    }
  }
  let body = Bytes::from_array(out)
  let flat = compress(body[:], 22, 1 << 24, contexts=true)
  let cut = compress(body[:], 22, 1 << 24, contexts=true, split=true)
  assert_eq(unbrotli(cut[:]), body)
  assert_true(cut.length() <= flat.length())
}

///|
/// A transform whose prefix is not empty is found by looking past the prefix: the
/// index is built on the word's own bytes, so the probe happens where the word
/// starts rather than where the match starts, and the length reported counts from
/// the match.
test "a prefixed transform is found past its prefix" {
  let index = DictIndex::build()
  let text = b"xx world"
  let (word, taken, _, transform) = index.find(text[:], 2, text.length())
  assert_eq(word, 5)
  assert_eq(taken, 6)
  let prefix = transforms[transform * 3]
  assert_true(prefix_suffix[prefix_suffix_map[prefix]].to_int() > 0)
}

///|
/// A shouted word is the same entry in upper case, which needs its own probe: the
/// hash is taken over the text's bytes, and every one of them differs from the
/// word's.
test "a shouted word finds its lowercase entry" {
  let index = DictIndex::build()
  let text = b"xxTIME"
  let (word, taken, _, transform) = index.find(text[:], 2, text.length())
  assert_eq(word, 4)
  assert_eq(taken, 4)
  assert_eq(transforms[transform * 3 + 1], TRANSFORM_UPPERCASE_ALL_KIND)
}

///|
/// A body of shouted words is smaller with the dictionary than without it: their
/// entries are lowercase, and the uppercase-all transform is what bridges the two.
test "shouted words compress and read back" {
  let words : Array[Bytes] = [b"TIME ", b"PEOPLE ", b"WORLD ", b"WORK "]
  let out : Array[Byte] = []
  for i in 0..<80 {
    for b in words[i % 4] {
      out.push(b)
    }
    for ch in i.to_string() {
      out.push((ch.to_int() & 0xFF).to_byte())
    }
    out.push(b' ')
  }
  let body = Bytes::from_array(out)
  let plain = compress(body[:], 22, 1 << 24, depth=1024)
  let words_out = compress(body[:], 22, 1 << 24, depth=1024, dictionary=true)
  assert_eq(unbrotli(plain[:]), body)
  assert_eq(unbrotli(words_out[:]), body)
  assert_true(words_out.length() < plain.length())
}

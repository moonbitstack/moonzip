// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The encoding side of an FSE table.
///
/// Decoding walks a table backwards; encoding walks it forwards, and the two are
/// built from the same distribution by spreading the symbols the same way. This
/// is the same table with a different view of it: `state_table` answers "which
/// state comes next", and the per-symbol transform answers "how many bits does
/// this symbol cost, and where does its state block start".
priv struct CTable {
  state_table : Array[Int32]
  delta_bits : Array[Int32]
  delta_find : Array[Int32]
  log : Int32
}

///|
fn CTable::build(counts : Array[Int32], log : Int32) -> CTable {
  let size = 1 << log
  let mask = size - 1
  let symbols = Array::make(size, 0)
  let cumul = Array::make(counts.length() + 1, 0)
  let mut high = size - 1
  for s in 0..<counts.length() {
    let c = counts[s]
    if c == -1 {
      cumul[s + 1] = cumul[s] + 1
      symbols[high] = s
      high -= 1
    } else {
      cumul[s + 1] = cumul[s] + c
    }
  }
  cumul[counts.length()] = size + 1
  let step = (size >> 1) + (size >> 3) + 3
  let mut position = 0
  for s in 0..<counts.length() {
    let c = counts[s]
    if c <= 0 {
      continue
    }
    for _ in 0..<c {
      symbols[position] = s
      position = (position + step) & mask
      while position > high {
        position = (position + step) & mask
      }
    }
  }
  // `position` returning to zero is the proof the walk filled every state; the
  // three distributions this is used with are the format's own, so a failure here
  // would be a mistake in the constants rather than in an archive.
  let state_table = Array::make(size, 0)
  let cursor = Array::make(counts.length() + 1, 0)
  for s in 0..<counts.length() {
    cursor[s] = cumul[s]
  }
  for u in 0..<size {
    let s = symbols[u]
    state_table[cursor[s]] = size + u
    cursor[s] += 1
  }
  let delta_bits = Array::make(counts.length() + 1, 0)
  let delta_find = Array::make(counts.length() + 1, 0)
  let mut total = 0
  for s in 0..<counts.length() {
    let c = counts[s]
    if c == 0 {
      delta_bits[s] = ((log + 1) << 16) - size
      delta_find[s] = 0
    } else if c == -1 || c == 1 {
      delta_bits[s] = (log << 16) - size
      delta_find[s] = total - 1
      total += 1
    } else {
      let max_out = log - highbit(c - 1)
      let min_state = c << max_out
      delta_bits[s] = (max_out << 16) - min_state
      delta_find[s] = total - c
      total += c
    }
  }
  { state_table, delta_bits, delta_find, log, }
}

///|
/// One encoding state. A sequence section carries three, interleaved.
priv struct CState {
  mut value : Int32
}

///|
/// Start in the state that has just encoded `symbol`, at the cheapest state that
/// can.
///
/// The decoder never updates the state after its *last* sequence, so the encoder
/// must not spend bits on it either — but the state still has to be the one that
/// symbol leaves behind, or the first three symbols a reader decodes are chosen
/// by the wrong state.
fn CState::init_for(table : CTable, symbol : Int32) -> CState {
  let transform = table.delta_bits[symbol]
  let nb = (transform + (1 << 15)) >> 16
  let value = (nb << 16) - transform
  { value: table.state_table[(value >> nb) + table.delta_find[symbol]], }
}

///|
fn CState::encode(
  self : CState,
  bits : Fwd,
  table : CTable,
  symbol : Int32,
) -> Unit {
  let nb = (self.value + table.delta_bits[symbol]) >> 16
  bits.take(self.value, nb)
  self.value = table.state_table[(self.value >> nb) + table.delta_find[symbol]]
}

///|
fn CState::flush(self : CState, bits : Fwd, table : CTable) -> Unit {
  bits.take(self.value, table.log)
}

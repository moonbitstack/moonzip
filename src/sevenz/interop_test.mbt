// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Archives written by 7-Zip, pinned as they came out.
///
/// These are the ones shipped with the py7zr project as test data. 7-Zip wrote
/// them, which is the point: our own writer can agree with our own reader about
/// a mistake, and only somebody else's bytes can say otherwise. Each read below
/// has to pass the checksums the archive itself carries, so "it decodes" means
/// "it decodes to what 7-Zip said it would".
///
///     python3 scripts/sevenz_vectors.py
///
/// regenerates this file.

///|
/// an archive of nothing at all.

///|
fn pinned_empty_7z() -> Bytes {
  @base16.decode_lossy(
    "377abcaf271c00038d9bd50f0000000000000000000000000000000000000000",
  )
}

///|
/// one file, one LZMA folder.

///|
fn pinned_lzma_1_7z() -> Bytes {
  @base16.decode_lossy(
    "377abcaf271c000492219a5d25000000000000005a00000000000000705c0eb2" +
    "002a1a09276419b03873ca8b1320af3a1b8d97f87c234de9e157d4e4974242d2" +
    "f6b9dd18000104060001092500070b01000123030101055d001000000c210008" +
    "0a013e6a6208000005011906000000000000111500740065007300740031002e" +
    "007400780074000000140a0100000845d9a010d601150601002080a4810000",
  )
}

///|
/// one file, stored — the shape that has a coder with no properties.

///|
fn pinned_copy_7z() -> Bytes {
  @base16.decode_lossy(
    "377abcaf271c0004a1df02f9ae00000000000000210000000000000091ba88f7" +
    "546869732066696c65206973206c6f636174656420696e206120666f6c646572" +
    "2e546869732066696c65206973206c6f636174656420696e2074686520726f6f" +
    "742e0000813307ae319a6903621069f208c3d6a4dac5a5205a3e66b9c6a9319e" +
    "f1a25f79142fc5e5f0309e85a0aaa2d4d9192f3c32df1ff986281c9b5af7b346" +
    "ab42909c3a5e0e5eca3cd2d477ba61be1131e1fb6ba351405c523009ac32ca26" +
    "c8b614389a27f6c35fc0d780000017064201096c00070b01000123030101055d" +
    "001000000c809a0a010298eb4d0000",
  )
}

///|
/// two files and a directory, with the header itself compressed.

///|
fn pinned_deflate_7z() -> Bytes {
  @base16.decode_lossy(
    "377abcaf271c0003e2dadadea1000000000000002100000000000000662311ae" +
    "75cac10900200805d055fe044dd302928a822498fb530b747a9737cd0fd443f0" +
    "8c5cd4c2f08d364165f6f8058266b0d4b80000813307ae0fd10ff6b8a090a072" +
    "43d459a89e0730d6f9ac389828951bc6ac5e2a2b13040c01a0cbf2c590f8548d" +
    "89a0194f39a3b5f1a0b5ee28fd5ad182177aabc5a2c2b77d65bc397c464432d6" +
    "79f7e34265ef83c76d1e8a017990e7d42f63a99163696d09b6e43a700a200000" +
    "0017063101097000070b01000123030101055d001000000c80970a01c58c3555" +
    "0000",
  )
}

///|
/// an LZMA2 folder followed by a delta filter.

///|
fn pinned_lzma2delta_1_7z() -> Bytes {
  @base16.decode_lossy(
    "377abcaf271c0004072be2256f0000000000000020000000000000002ea59edb" +
    "01000a6210efbf4210efbf4210ef000000813307ae0fcedd0761090a900f6218" +
    "ed01c426dd61e3a240bf48e1b5ba90b5fa9c6b40562ae682218413a03f251202" +
    "2a3a2beffcb3361f7b955197227c849fdcb53bc8cc850c56d8a0b093afd24372" +
    "40d2d5f1d3461c742104f6b4ccb80017060f01096000070b0100012303010105" +
    "5d001000000c760a01b1b62a1b0000",
  )
}

///|
/// a name outside ASCII, which only survives as UTF-16.

///|
fn pinned_umlaut_solid_7z() -> Bytes {
  @base16.decode_lossy(
    "377abcaf271c00029490299033000000000000005000000000000000070698a0" +
    "002a1a09276419b03873ca8abb9502c17ff728f9ae302473fc0eb504f21a94ae" +
    "717e00aae335e6dc83eabec7e323a82d2c7e4c0104060001093300070b010001" +
    "23030101055d000000020c3300080a01663a2480000005011113007400e40073" +
    "0074002e007400780074000000140a0100e27b4fb68148c60115060100200000" +
    "000000",
  )
}

///|
/// members with no content of their own.

///|
fn pinned_zerosize_7z() -> Bytes {
  @base16.decode_lossy(
    "377abcaf271c0004952660a5700000000000000021000000000000001d7eb2b4" +
    "010001310a000000813307ae0fdab1c8f5c247793baab942044d5b253eb1c417" +
    "c76605603d0c63bf26ae140c6e7b1f3019be244ea56e5bb525bcdb5d1dde2e7f" +
    "41ff70e012d7c775f4fdb1f529864bd94fe591ae1549cc6089197ed29dc73cff" +
    "c8b4d9e256b2be84b2c260cd0000000017060601096a00070b01000123030101" +
    "055d001000000c808a0a01c52726fc0000",
  )
}

///|
/// three files in one folder, so the substream table is used.

///|
fn pinned_solid_7z() -> Bytes {
  @base16.decode_lossy(
    "377abcaf271c000485423782a8000000000000002100000000000000d0f97031" +
    "e00041002f5d002a1a09276419b03873ca8b1320af3a1b8d97f87c234de9eb1c" +
    "337bb1b647fd217944eee6af3cb0b328df5b9ac74a00000000813307ae0fd16a" +
    "c5a0a090a0775ec54018921baea858611732571699faf17a749a6f6ce1242bb9" +
    "293ad05b9c5dbb1614d060f4fdce62689354c9b4b9f608e805d1c1b28a93a8f3" +
    "4bfd629d34aaa2c495cfe29dd78e1586a6aaacddcd28c79d94aa9697777086c1" +
    "38a72c4e5c00000017063701097100070b01000123030101055d001000000c80" +
    "9a0a019116292a0000",
  )
}

///|
/// Every one of them has to read, and the checksums inside them have
/// to agree with what came out.
test "archives written by 7-Zip read back" { // empty.7z
  {
    let members = @sevenz.un7z(pinned_empty_7z()[:])
    assert_eq(members.length(), 0)
  } // lzma_1.7z
  {
    let members = @sevenz.un7z(pinned_lzma_1_7z()[:])
    assert_true(members.length() > 0)
  } // copy.7z
  {
    let members = @sevenz.un7z(pinned_copy_7z()[:])
    assert_true(members.length() > 0)
  } // deflate.7z
  {
    let members = @sevenz.un7z(pinned_deflate_7z()[:])
    assert_true(members.length() > 0)
  } // lzma2delta_1.7z
  {
    let members = @sevenz.un7z(pinned_lzma2delta_1_7z()[:])
    assert_true(members.length() > 0)
  } // umlaut-solid.7z
  {
    let members = @sevenz.un7z(pinned_umlaut_solid_7z()[:])
    assert_true(members.length() > 0)
  } // zerosize.7z
  {
    let members = @sevenz.un7z(pinned_zerosize_7z()[:])
    assert_true(members.length() > 0)
  } // solid.7z
  let members = @sevenz.un7z(pinned_solid_7z()[:])
  assert_true(members.length() > 0)
}

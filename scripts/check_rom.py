#!/usr/bin/env python3
"""Structural verification of a CMP 170HX VBIOS ROM.

Why not md5: the 1MB SPI image contains a per-boot dynamic data region
(0xC2000+), so dumps of identical ROMs from two sources never hash the same.
Instead we check structural markers established by independent reverse
engineering (amoghmunikote's GA100 VBIOS comparison gist):

  - NVGI header magic "NVGI"
  - Device ID 0x20C2, Subsystem 0x1585  (via nvflash --version, run separately)
  - power limit encoding:  250W = 90 D0 03 @0x45E45   (250W build 92.00.67.*)
                           300W = E0 93 04 @0x46045   (300W build 92.00.6D.*)
  - CFG1 strap tier byte @0x41D53 (250W) / @0x41F53 (300W) must be 0x44
    (0x44 = NERFED stock; 0x66 would mean a memory-capacity forger's ROM)
  - license/HULK region @0xFE504 all-zero (placeholder, not a forged cert)
  - duplicated image at +0x60000 (dual-bank layout)

Usage: python3 check_rom.py <file.rom> [--expect 250W|300W]
"""
import sys

MARKERS = {
    "250W": {
        "size": 1044480,
        "power_off": 0x45E45, "power_bytes": bytes([0x90, 0xD0, 0x03]),
        "strap_off": 0x41D53, "strap_val": 0x44,
    },
    "300W": {
        "size": 1044480,
        "power_off": 0x46045, "power_bytes": bytes([0xE0, 0x93, 0x04]),
        "strap_off": 0x41F53, "strap_val": 0x44,
    },
}


def hx(b, o, n=8):
    return b[o:o + n].hex(" ")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    path = sys.argv[1]
    expect = None
    if "--expect" in sys.argv:
        expect = sys.argv[sys.argv.index("--expect") + 1]

    data = open(path, "rb").read()
    print(f"file: {path}  size: {len(data)}")
    fails = 0

    if data[:4] != b"NVGI":
        print(f"  ❌ NVGI magic missing: {hx(data, 0, 4)}")
        fails += 1
    else:
        print("  ✅ NVGI magic")

    matches = []
    for name, m in MARKERS.items():
        if len(data) != m["size"]:
            print(f"  ⚠️  {name}: unexpected size {len(data)} (want {m['size']})")
            continue
        power_ok = data[m["power_off"]:m["power_off"] + 3] == m["power_bytes"]
        strap_ok = data[m["strap_off"]] == m["strap_val"]
        if power_ok and strap_ok:
            matches.append(name)
            print(f"  ✅ matches {name} build (power {hx(data, m['power_off'], 3)} @"
                  f"{hex(m['power_off'])}, strap 0x{data[m['strap_off']]:02x} @{hex(m['strap_off'])})")
        else:
            print(f"  ·  not a {name} build (power @ {hex(m['power_off'])} = "
                  f"{hx(data, m['power_off'], 3)}, strap @ {hex(m['strap_off'])} = 0x{data[m['strap_off']]:02x})")

    if expect:
        if expect in matches:
            print(f"  ✅ expected {expect}: confirmed")
        else:
            print(f"  ❌ expected {expect} but markers did not confirm")
            fails += 1
    elif not matches:
        print("  ❌ matches neither known 170HX build - DO NOT FLASH")
        fails += 1

    # license region: must be the empty placeholder (all zero), never a cert blob
    lic = data[0xFE504:0xFE510]
    if all(b == 0 for b in lic):
        print("  ✅ license region @0xFE504 = empty placeholder (no forged cert)")
    else:
        print(f"  ⚠️  license region non-zero: {hx(lic, 0, 6)} - treat as MODIFIED, do not flash")

    # dual-bank mirror sanity: bytes far in the tail should mirror +0x60000
    if len(data) >= 0xC0000:
        tail_same = sum(1 for i in range(0x48000, 0x5FFFF) if data[i] == data[i + 0x60000])
        print(f"  ·  dual-bank mirror agreement 0x48000-0x5FFFF vs +0x60000: "
              f"{tail_same}/{0x5FFFF-0x48000}")

    if fails:
        print("RESULT: FAIL")
        sys.exit(1)
    print(f"RESULT: OK ({'/'.join(matches) if matches else 'see notes'})")


if __name__ == "__main__":
    main()

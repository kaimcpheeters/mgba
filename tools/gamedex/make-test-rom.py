#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Emit original test-rom.s machine code with a minimal GBA header (no Nintendo logo)."""
import pathlib
import struct
import sys
CODE = bytes.fromhex(
    '0103a0e30310a0e3011b81e3b010c0e10624a0e31f30a0e3964ca0e3b230c2e0'
    '014054e2fcffff1a8010a0e3b418c0e1771ca0e3771081e3b018c0e10210a0e3'
    'b218c0e10f1aa0e3801081e3b216c0e10219a0e3011b81e3b416c0e1b610d0e1'
    'a00051e3fcffff1a015c80e2b013d5e1010011e31f30a0031f3ba0130624a0e3'
    'b030c2e1b610d0e1a00051e3fcffff0af1ffffea')
rom = bytearray(1024)
struct.pack_into('<I', rom, 0, 0xea00002e)
rom[0xa0:0xac] = b'CAPTURE TEST'
rom[0xac:0xb2] = b'TEST00'
rom[0xb2] = 0x96
rom[0xbd] = (-sum(rom[0xa0:0xbd]) - 0x19) & 255
rom[0xc0:0xc0+len(CODE)] = CODE
pathlib.Path(sys.argv[1]).write_bytes(rom)

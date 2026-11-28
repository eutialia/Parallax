#!/bin/bash
# Regenerates the subtitle fixtures that cannot be typed: legacy encodings of the UTF-8 twins,
# a UTF-8 file with one damaged byte, a CRLF script, and an ASS file carrying an embedded font.
# Usage: scripts/gen-subtitle-fixtures.sh    (needs macOS iconv, perl and python3)
set -euo pipefail

OUT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)/Packages/ParallaxSubtitles/Tests/ParallaxSubtitlesTests/Fixtures"

iconv -f UTF-8 -t GB18030 "$OUT/legacy/gbk.utf8.ass" > "$OUT/legacy/gbk.ass"
iconv -f UTF-8 -t BIG5 "$OUT/legacy/big5.utf8.ass" > "$OUT/legacy/big5.ass"
iconv -f UTF-8 -t SHIFT_JIS "$OUT/legacy/shift-jis.utf8.ass" > "$OUT/legacy/shift-jis.ass"
iconv -f UTF-8 -t EUC-KR "$OUT/legacy/euc-kr.utf8.ass" > "$OUT/legacy/euc-kr.ass"
iconv -f UTF-8 -t CP1252 "$OUT/latin1.utf8.ass" > "$OUT/latin1.ass"

# A stray lead byte in a header comment, nowhere near the dialogue.
perl -pe 's/^; Timed/; \xC3Timed/' "$OUT/utf8-clean.ass" > "$OUT/utf8-one-bad-byte.ass"

perl -pe 's/\n/\r\n/' "$OUT/lf-reordered.ass" > "$OUT/crlf-reordered.ass"

# A one-glyph TrueType font whose "A" is a solid square, attached the way ASS attaches fonts:
# 6-bit groups offset by 33, 80 characters a line.
python3 -I - "$OUT/embedded-font.ass" <<'PY'
import struct, sys

FAMILY = "ParallaxEmbeddedProbe"
UPM = 1000

def table_checksum(data):
    data += b"\0" * (-len(data) % 4)
    return sum(struct.unpack(f">{len(data) // 4}L", data)) & 0xFFFFFFFF

def square_glyph():
    points = [(50, 0), (50, 700), (650, 700), (650, 0)]
    flags = bytes([0x01] * 4)
    xs = b"".join(struct.pack(">h", x - px) for (x, _), (px, _) in zip(points, [(0, 0)] + points[:-1]))
    ys = b"".join(struct.pack(">h", y - py) for (_, y), (_, py) in zip(points, [(0, 0)] + points[:-1]))
    return struct.pack(">hhhhhH", 1, 50, 0, 650, 700, 3) + struct.pack(">H", 0) + flags + xs + ys

glyphs = [b"", square_glyph()]
glyf = b"".join(g + b"\0" * (-len(g) % 4) for g in glyphs)
offsets = [0]
for g in glyphs:
    offsets.append(offsets[-1] + len(g) + (-len(g) % 4))

def name_table():
    records = [(1, FAMILY), (2, "Regular"), (4, FAMILY), (6, FAMILY)]
    strings = b""
    entries = b""
    for name_id, text in records:
        encoded = text.encode("utf-16-be")
        entries += struct.pack(">HHHHHH", 3, 1, 0x409, name_id, len(encoded), len(strings))
        strings += encoded
    return struct.pack(">HHH", 0, len(records), 6 + 12 * len(records)) + entries + strings

cmap_subtable = struct.pack(">HHHHHHH", 4, 32, 0, 4, 4, 1, 0) + struct.pack(">HH", 0x41, 0xFFFF) + struct.pack(">H", 0) \
    + struct.pack(">HH", 0x41, 0xFFFF) + struct.pack(">hh", 1 - 0x41, 1) + struct.pack(">HH", 0, 0)
tables = {
    b"cmap": struct.pack(">HHHHL", 0, 1, 3, 1, 12) + cmap_subtable,
    b"glyf": glyf,
    b"head": struct.pack(">LLLLHHqqhhhhHHhhh", 0x00010000, 0x00010000, 0, 0x5F0F3CF5, 0x000B, UPM, 0, 0,
                         0, 0, 650, 700, 0, 8, 2, 1, 0),
    b"hhea": struct.pack(">LhhhHhhhhhhhhhhhH", 0x00010000, 800, -200, 0, 700, 0, 0, 650, 1, 0, 0, 0, 0, 0, 0, 0, 2),
    b"hmtx": struct.pack(">HhHh", 500, 0, 700, 50),
    b"loca": struct.pack(">3L", *offsets),
    b"maxp": struct.pack(">LHHHHHHHHHHHHHH", 0x00010000, 2, 4, 1, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0),
    b"name": name_table(),
    b"OS/2": struct.pack(">HhHHHhhhhhhhhhhh10s4L4sHHHhhhHHLLhhHHH", 4, 500, 400, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                         bytes(10), 1, 0, 0, 0, b"NONE", 0x40, 0x41, 0x41, 800, -200, 0, 800, 200, 1, 0,
                         500, 700, 0, 0x41, 1),
    b"post": struct.pack(">LLhhLLLLL", 0x00030000, 0, -100, 50, 0, 0, 0, 0, 0),
}
tags = sorted(tables)
header = struct.pack(">LHHHH", 0x00010000, len(tags), 128, 3, len(tags) * 16 - 128)
directory = b""
body = b""
offset = 12 + 16 * len(tags)
for tag in tags:
    data = tables[tag]
    directory += struct.pack(">4sLLL", tag, table_checksum(data), offset + len(body), len(data))
    body += data + b"\0" * (-len(data) % 4)
font = bytearray(header + directory + body)
adjustment = (0xB1B0AFBA - table_checksum(bytes(font))) & 0xFFFFFFFF
head_offset = struct.unpack(">L", directory[16 * tags.index(b"head") + 8:16 * tags.index(b"head") + 12])[0]
font[head_offset + 8:head_offset + 12] = struct.pack(">L", adjustment)

def ass_encoded(data):
    out = []
    for i in range(0, len(data), 3):
        chunk = data[i:i + 3]
        value = int.from_bytes(chunk + b"\0" * (3 - len(chunk)), "big")
        groups = [(value >> shift) & 0x3F for shift in (18, 12, 6, 0)][:len(chunk) + 1]
        out.extend(chr(g + 33) for g in groups)
    text = "".join(out)
    return "\n".join(text[i:i + 80] for i in range(0, len(text), 80))

script = f"""[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,{FAMILY},28,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,2,20,20,20,1

[Fonts]
fontname: {FAMILY}_0.ttf
{ass_encoded(bytes(font))}

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:01.90,Default,,0,0,0,,A
"""
open(sys.argv[1], "w", newline="").write(script)
PY

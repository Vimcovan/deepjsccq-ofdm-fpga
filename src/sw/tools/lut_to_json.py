"""Convert the PL init table (ad9361_config_lut.v) into the PS init script ad9361_rx_init.json.

    python lut_to_json.py [lut.v] [out.json]

Entry {1'b1, addr, data} = write; {1'b0, addr, data} = read, which the PL engine (ad9361_config.v) repeats until a
condition holds (POLL below, copied from its case table) or a delay (addr 0x3FF: data 0x01 = 1 ms, 0x14 = 20 ms,
0xFF = end). Other reads are plain reads (done once).
"""
import json
import re
import sys

LUT = sys.argv[1] if len(sys.argv) > 1 else r"D:\ClaudePrj\AD9361\OFDM_JSCC_PS_RX\rtl\phy\ad9361_config_lut.v"
OUT = sys.argv[2] if len(sys.argv) > 2 else r"D:\ClaudePrj\AD9361\jscc_link\ad9361_rx_init.json"
# (addr, lut data) -> (mask, wanted value) of the read data, as in ad9361_config.v state 3
POLL = {(0x037, 0x08): (0x08, 0x08), (0x05E, 0x80): (0x80, 0x80), (0x244, 0x80): (0x80, 0x80),
        (0x284, 0x80): (0x80, 0x80), (0x247, 0x02): (0x02, 0x02), (0x287, 0x02): (0x02, 0x02),
        (0x016, 0x80): (0x80, 0x00), (0x016, 0x40): (0x40, 0x00), (0x016, 0x01): (0x01, 0x00),
        (0x016, 0x02): (0x02, 0x00), (0x016, 0x10): (0x10, 0x00), (0x016, 0x20): (0x20, 0x00),
        (0x017, 0x0F): (0x0F, 0x0A)}                               # ENSM state 10 = FDD

src = open(LUT, encoding="utf-8", errors="replace").read()
ent = re.findall(r"11'd(\d+)\s*:\s*ad9361_config_lut\s*=\s*\{1'b([01]),10'h([0-9A-Fa-f]+),8'h([0-9A-Fa-f]+)\}\s*;\s*(//[^\n]*)?", src)
ent = sorted((int(i), int(w), int(a, 16), int(d, 16), (c or "")[2:].strip()) for i, w, a, d, c in ent)
assert [e[0] for e in ent] == list(range(len(ent))), "LUT indices not contiguous"
ops = []
for i, w, a, d, c in ent:
    if w:
        ops.append(["w", a, d, c])
    elif a == 0x3FF:
        if d == 0xFF:
            break
        ops.append(["delay", {0x01: 1, 0x14: 20}.get(d, 1), c])
    elif (a, d) in POLL:
        m, v = POLL[(a, d)]
        ops.append(["poll", a, m, v, c])
    else:
        ops.append(["r", a, c])
json.dump(dict(source=LUT, ops=ops), open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=0)
n = {k: sum(1 for o in ops if o[0] == k) for k in ("w", "r", "poll", "delay")}
print(f"{len(ops)} ops -> {OUT}: {n}")

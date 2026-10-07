"""Python reference of the SSCC TX chain (sscc_tx.sv), independent of the RTL:
    bytes -> 802.11 scrambler (x^7 + x^4 + 1, seed 1011101, per frame) + zero tail -> K=7 (171,133) rate 1/2
    -> 802.11a interleaver N_CBPS = 384, s = 3 -> Gray 64-QAM 158 * {+-1..+-7}
Used to check tx_syms.txt / tx_bytes.txt dumped by tb_sscc (+DUMP=1), and by the PS side (pack / unpack).

    python sscc_ref.py <sim dir>
"""
import sys
import numpy as np

PAY_BYTES, FRAME_SYMS = 12272, 32768
FRAME_BITS = FRAME_SYMS * 3
N, S = 384, 3


def scramble(bits, seed=0b1011101):
    st = [(seed >> (6 - i)) & 1 for i in range(7)]          # st[0] = bit 6 ... st[6] = bit 0
    out = np.empty_like(bits)
    for n, b in enumerate(bits):
        fb = st[0] ^ st[3]                                    # bit 6 ^ bit 3
        out[n] = b ^ fb
        st = st[1:] + [fb]                                    # {st[5:0], fb}
    return out


def conv(bits):
    sr = [0] * 6                                              # sr[0] = previous input
    out = np.empty(2 * len(bits), np.uint8)
    for n, b in enumerate(bits):
        w = [b] + sr                                          # w[0] = input, w[6] = 6 delays
        g0 = [1, 1, 1, 1, 0, 0, 1]                            # 171 (MSB = input)
        g1 = [1, 0, 1, 1, 0, 1, 1]                            # 133
        out[2 * n] = sum(x & g for x, g in zip(w, g0)) & 1
        out[2 * n + 1] = sum(x & g for x, g in zip(w, g1)) & 1
        sr = [b] + sr[:5]
    return out


def perm(k):
    i = (N // 16) * (k % 16) + k // 16
    return S * (i // S) + (i + N - (16 * i) // N) % S


P = np.array([perm(k) for k in range(N)])
assert sorted(P) == list(range(N))


def interleave(cb):
    out = np.empty_like(cb)
    for b in range(len(cb) // N):
        blk = cb[b * N:(b + 1) * N]
        o = np.empty_like(blk); o[P] = blk
        out[b * N:(b + 1) * N] = o
    return out


def lvl(g):                                                  # g = (msb, mid, lsb) Gray -> 158 (2k - 7)
    g = [int(x) for x in g]
    k2 = g[0]; k1 = g[0] ^ g[1]; k0 = g[0] ^ g[1] ^ g[2]
    return 158 * (2 * (4 * k2 + 2 * k1 + k0) - 7)


def tx(payload):
    assert len(payload) == PAY_BYTES
    bits = np.unpackbits(np.frombuffer(payload, np.uint8))  # MSB first
    bits = np.concatenate([scramble(bits), np.zeros(FRAME_BITS - len(bits), np.uint8)])
    cb = interleave(conv(bits))
    sb = cb.reshape(-1, 6)
    return np.array([[lvl(r[0:3]), lvl(r[3:6])] for r in sb])     # (I, Q)


if __name__ == "__main__":
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    pay = bytes(int(l, 16) for l in open(f"{d}/tx_bytes.txt"))
    rtl = np.loadtxt(f"{d}/tx_syms.txt", dtype=int)
    ref = tx(pay)
    n = min(len(rtl), len(ref))
    bad = np.flatnonzero(np.any(rtl[:n] != ref[:n], axis=1))
    print(f"reference {len(ref)} symbols, RTL {len(rtl)}: {len(bad)} mismatches"
          + (f", first at {bad[0]}: rtl {rtl[bad[0]]} ref {ref[bad[0]]}" if len(bad) else ""))

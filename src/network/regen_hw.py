"""Regenerate the network RTL from the quantized export and update src/hw.

    python src/network/regen_hw.py

1. gen_rtl_init.py: data/model/params + manifest.json -> data/model/rtl_init/<engine>/*.mem, engine.json
2. gen_rtl_top.py:  blk_enc_0_latent_idx (TX) and blk_rx_in_output (RX) -> src/network/gen/
3. the absolute $readmemh paths in the two tops are replaced by unique file names
   (<dir>__<subdir>__<file>.mem, what Vivado projects expect), and the referenced .mem files are copied to
   src/hw/{tx,rx}/rtl/network/mem/; the tops go to src/hw/{tx,rx}/rtl/network/rtl/.

All files are written with LF line ends, so an unchanged export leaves the work tree without changes: that is the check
that the committed RTL comes from the committed model (check with `git diff --stat`; on Windows `git status` may list
files whose content is unchanged).
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
EXP = REPO / 'data' / 'model'
GEN = HERE / 'gen'
TOPS = {'tx': (('enc.0', 'latent_idx'), 'blk_enc_0_latent_idx'),
        'rx': (('rx_in', 'output'), 'blk_rx_in_output')}


def run(*args):
    print('>', ' '.join(str(a) for a in args), flush=True)
    subprocess.run([sys.executable, *map(str, args)], check=True)


def local_name(path: Path) -> str:
    return '__'.join(path.relative_to(EXP).parts)


def install(side: str, top: str):
    text = (GEN / f'{top}.sv').read_text(encoding='ascii')
    dst = REPO / 'src' / 'hw' / side / 'rtl' / 'network'
    copied = set()
    for ref in sorted(set(re.findall(r'"([^"\r\n]+)"', text))):
        p = Path(ref)
        if not p.is_absolute():
            continue
        # weight ROM parameters are prefixes (.../wrom); the RTL appends .mem, _sN.mem, _g_cN.mem ...
        files = [p] if p.is_file() else sorted(x for x in p.parent.glob(p.name + '*') if x.is_file())
        if not files:
            raise FileNotFoundError(ref)
        for f in files:
            shutil.copyfile(f, dst / 'mem' / local_name(f))
            copied.add(local_name(f))
        text = text.replace(f'"{ref}"', f'"{local_name(p)}"')
    (dst / 'rtl' / f'{top}.sv').write_text(text, encoding='ascii', newline='\n')
    extra = sorted({f.name for f in (dst / 'mem').glob('*.mem')} - copied)
    print(f'{side}: {top}.sv, {len(copied)} .mem files' + (f'; not referenced: {extra}' if extra else ''))


def main():
    run(HERE / 'gen_rtl_init.py', '--export', EXP)
    for side, ((first, last), top) in TOPS.items():
        run(HERE / 'gen_rtl_top.py', first, last, '--export', EXP, '--out', GEN)
        install(side, top)
    print('done; `git diff --stat` lists every file that differs from the committed RTL')


if __name__ == '__main__':
    main()

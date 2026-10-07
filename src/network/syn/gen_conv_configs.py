"""Write syn/conv_configs.tcl (engine generics for synth_conv_engine.tcl) from rtl_init/*/engine.json."""
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
init = root / 'runs' / 'fpga_export_w8a12' / 'rtl_init'
engines = sys.argv[1:] or ['enc.0.conv1', 'enc.0.conv2', 'enc.2.conv1', 'enc.3.ab0.c0', 'enc.3.a0.c1',
                           'dec.2.conv+skip', 'dec.7.conv+skip']
man = json.loads((root / 'runs' / 'fpga_export_w8a12' / 'manifest.json').read_text(encoding='utf-8'))
plan_eng = {e['name']: e for part in ('encoder', 'decoder') for e in man['memory_plan'][part]['engines']}
lines = ['set configs {']
for name in engines:
    e = json.loads((init / name / 'engine.json').read_text(encoding='utf-8'))
    g = [f"CIN={e['CIN']}", f"COUT={e['COUT']}", f"K={e['K']}", f"P={e['P']}",
         f'ACT="{e["ACT"]}"', f'ACT2="{e["ACT2"]}"', f"ACT_SPLIT={e['ACT_SPLIT']}",
         f'WROM_STYLE="{e["WROM_STYLE"]}"', f'WROM_MODE="{e["WROM_MODE"]}"', f"WG_NCOL={e['WG_NCOL']}",
         f"WROM_BANK_DEPTH={e['WROM_BANK_DEPTH']}", f'RQ_MUL="{e["RQ_MUL"]}"', f"PRE={e['PRE']}", f"SH_MIN={e['SH_MIN']}", f"SH_BITS={e['SH_BITS']}"]
    pe = plan_eng[name]
    rq = 1 if e['RQ_MUL'] == 'dsp' else 0
    plan = (f"P={e['P']} mode={e['WROM_MODE']}/{e['WROM_STYLE']} rq={e['RQ_MUL']}: "
            f"expect ROM {pe['b18'] / 2:g} BRAM36 ({pe['prim']}), DSP {e['P'] + rq}")
    lines.append(f'    {name} {{{" ".join(g)}}} {{{plan}}}')
lines.append('}')
(root / 'syn' / 'conv_configs.tcl').write_text('\n'.join(lines) + '\n', encoding='ascii')
print('\n'.join(lines))

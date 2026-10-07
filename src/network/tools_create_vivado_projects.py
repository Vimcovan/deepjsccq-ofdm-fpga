from pathlib import Path
import json
import re
import shutil
import argparse

ROOT = Path(r"D:\CodexPrj\DeepJSCC-Q-FPGA")
EXPORT = ROOT / "runs" / "fpga_export_w8a12"
OUT_ROOT = ROOT / "vivado_projects"
PART = "xczu5eg-sfvc784-1-e"

PROJECTS = {
    "encoder": ("encoder_zu5eg", "blk_enc_0_latent_idx"),
    "decoder": ("decoder_zu5eg", "blk_rx_in_output"),
}


def copy_mem_assets(top_text: str, out_dir: Path):
    abs_re = re.compile(r'"(D:/[^"\r\n]+)"')
    refs = sorted({m.group(1) for m in abs_re.finditer(top_text)})
    rewritten = top_text
    copied = []
    destinations = {}
    def basename(path):
        return "__".join(path.relative_to(EXPORT).parts).replace("+", "_plus_")
    def copy_one(path):
        name = basename(path)
        if name.casefold() in destinations and destinations[name.casefold()] != path:
            raise RuntimeError(f"Memory filename collision: {name}")
        destinations[name.casefold()] = path
        dst = out_dir / "mem" / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dst)
        if path.read_bytes() != dst.read_bytes():
            raise RuntimeError(f"Copy mismatch: {name}")
        copied.append(name)
    for ref in refs:
        src = Path(ref.replace("/", "\\"))
        try:
            rel = src.relative_to(EXPORT)
        except ValueError as exc:
            raise RuntimeError(f"top references file outside export: {ref}") from exc
        if src.is_file():
            copy_one(src)
        elif src.is_dir():
            for child in src.rglob("*"):
                if child.is_file():
                    copy_one(child)
        else:
            # Weight ROM parameters are prefixes (for example ``.../wrom``)
            # and the RTL appends ``.mem`` or ``_sN.mem`` at elaboration.
            matches = sorted(src.parent.glob(src.name + "*") )
            if not matches or not all(m.is_file() for m in matches):
                raise FileNotFoundError(ref)
            for child in matches:
                copy_one(child)
        local = basename(src)
        rewritten = rewritten.replace(f'"{ref}"', f'"{local}"')
    return rewritten, sorted(set(copied)), refs


def write_create_tcl(out_dir: Path, project_name: str, top: str):
    text = f'''# Auto-generated self-contained Vivado project for {top}.
set project_dir [file normalize [file join [file dirname [info script]] ..]]
cd $project_dir
set_param general.maxThreads 4
create_project -force {project_name} $project_dir -part {PART}
set_property target_language Verilog [current_project]
set rtl_files [glob -nocomplain -types f [file join $project_dir rtl *.sv]]
add_files -norecurse -fileset sources_1 $rtl_files
set mem_files [glob -nocomplain -types f [file join $project_dir mem *.mem]]
if {{[llength $mem_files] > 0}} {{ add_files -norecurse -fileset sources_1 $mem_files }}
add_files -norecurse -fileset constrs_1 [file join $project_dir constr clk_250.xdc]
set_property top_auto_set 0 [get_filesets sources_1]
set_property top {top} [get_filesets sources_1]
update_compile_order -fileset sources_1
if {{[llength [get_runs -quiet synth_1]] == 0}} {{
    create_run synth_1 -flow {{Vivado Synthesis 2025}} -strategy Flow_Default
}}
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
set_property INCREMENTAL_CHECKPOINT "" [get_runs synth_1]
puts "PROJECT_CREATED {project_name} TOP={top} SOURCES=[llength $rtl_files] MEM=[llength $mem_files]"
close_project
'''
    (out_dir / "scripts" / "create_project.tcl").write_text(text, encoding="utf-8")


def write_validate_tcl(out_dir: Path, project_name: str, top: str):
    text = f'''# Open the project and verify that all sources and constraints are registered.
set project_dir [file normalize [file join [file dirname [info script]] ..]]
cd $project_dir
open_project [file join $project_dir {project_name}.xpr]
update_compile_order -fileset sources_1
set src_count [llength [get_files -of_objects [get_filesets sources_1]]]
set top_name [get_property top [get_filesets sources_1]]
puts "PROJECT_VALID {project_name} TOP=$top_name FILES=$src_count"
close_project
'''
    (out_dir / "scripts" / "validate_project.tcl").write_text(text, encoding="utf-8")


def write_project_synth_tcl(out_dir: Path, project_name: str, top: str):
    text = f'''# Project-based out-of-context synthesis check.
set project_dir [file normalize [file join [file dirname [info script]] ..]]
cd $project_dir
open_project [file join $project_dir {project_name}.xpr]
set_param general.maxThreads 4
synth_design -top {top} -part {PART} -mode out_of_context
file mkdir [file join $project_dir reports]
report_utilization -file [file join $project_dir reports {top}.util.rpt]
report_timing_summary -max_paths 10 -file [file join $project_dir reports {top}.timing.rpt]
set r36 [llength [get_cells -quiet -hier -filter {{REF_NAME == RAMB36E2}}]]
set r18 [llength [get_cells -quiet -hier -filter {{REF_NAME == RAMB18E2}}]]
set uram [llength [get_cells -quiet -hier -filter {{REF_NAME == URAM288}}]]
set dsp [llength [get_cells -quiet -hier -filter {{REF_NAME == DSP48E2}}]]
set wns [get_property SLACK [lindex [get_timing_paths -quiet -max_paths 1 -setup] 0]]
puts [format "PROJECT_RESULT {top} RAMB36=%d RAMB18=%d (=%.1f BRAM36) URAM=%d DSP=%d WNS=%s ns" $r36 $r18 [expr {{$r36 + $r18 / 2.0}}] $uram $dsp $wns]
close_project
'''
    (out_dir / "scripts" / "project_synth.tcl").write_text(text, encoding="utf-8")


def write_run_tcl(out_dir: Path, project_name: str, top: str):
    expected_dsp, expected_uram = (233, 4) if project_name.startswith('encoder') else (312, 18)
    text = f'''set project_dir [file normalize [file join [file dirname [info script]] ..]]
cd $project_dir
open_project [file join $project_dir {project_name}.xpr]
set old_mem [get_files -quiet -of_objects [get_filesets sources_1] -filter {{FILE_TYPE == "Memory Initialization Files"}}]
if {{[llength $old_mem]}} {{ remove_files $old_mem }}
set mem_files [glob -types f [file join $project_dir mem *.mem]]
add_files -norecurse -fileset sources_1 $mem_files
set_property top {top} [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
set_property INCREMENTAL_CHECKPOINT "" [get_runs synth_1]
update_compile_order -fileset sources_1
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {{[get_property PROGRESS [get_runs synth_1]] ne "100%"}} {{ error "synth_1 did not complete" }}
open_run synth_1
file mkdir [file join $project_dir reports]
report_utilization -file [file join $project_dir reports filename_only.util.rpt]
report_timing_summary -file [file join $project_dir reports filename_only.timing.rpt]
set r36 [llength [get_cells -quiet -hier -filter {{REF_NAME == RAMB36E2}}]]
set r18 [llength [get_cells -quiet -hier -filter {{REF_NAME == RAMB18E2}}]]
set uram [llength [get_cells -quiet -hier -filter {{REF_NAME == URAM288}}]]
set dsp [llength [get_cells -quiet -hier -filter {{REF_NAME == DSP48E2}}]]
puts "FILENAME_RESULT {top} RAMB36=$r36 RAMB18=$r18 BRAM36_EQ=[expr {{$r36+$r18/2.0}}] URAM=$uram DSP=$dsp"
if {{$dsp != {expected_dsp} || $uram != {expected_uram} || $r36+$r18/2.0 != 100}} {{ error "Resource regression: compare with validated design" }}
puts "FILENAME_SYNTH_PASS {top}"
close_project
'''
    (out_dir / "scripts" / "run_synth.tcl").write_text(text, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--refresh-assets', action='store_true', help='Update copied assets without deleting projects or run results')
    args = parser.parse_args()
    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    common_rtl = sorted((ROOT / "rtl").glob("*.sv"))
    for key, (project_name, top) in PROJECTS.items():
        out = OUT_ROOT / key
        if out.exists() and not args.refresh_assets:
            raise FileExistsError(f"Project exists; use --refresh-assets to preserve and update: {out}")
        (out / "rtl").mkdir(parents=True, exist_ok=True)
        (out / "constr").mkdir(parents=True, exist_ok=True)
        (out / "scripts").mkdir(parents=True, exist_ok=True)
        for legacy_mem in (out / "mem" / "rtl_init", out / "mem" / "params"):
            if legacy_mem.exists():
                shutil.rmtree(legacy_mem)
        for src in common_rtl:
            shutil.copy2(src, out / "rtl" / src.name)
        source_top = ROOT / "rtl" / "gen" / f"{top}.sv"
        top_text, copied, refs = copy_mem_assets(source_top.read_text(encoding="utf-8"), out)
        (out / "rtl" / f"{top}.sv").write_text(top_text, encoding="utf-8")
        shutil.copy2(ROOT / "rtl" / "gen" / f"{top}.json", out / "rtl" / f"{top}.json")
        shutil.copy2(ROOT / "syn" / "clk_250.xdc", out / "constr" / "clk_250.xdc")
        manifest = {
            "project": project_name,
            "top": top,
            "part": PART,
            "source_rtl_count": len(common_rtl) + 1,
            "memory_file_count": len(copied),
            "memory_files": copied,
            "original_absolute_references": len(refs),
            "source_top": str(source_top),
        }
        (out / "project_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        write_create_tcl(out, project_name, top)
        write_validate_tcl(out, project_name, top)
        write_project_synth_tcl(out, project_name, top)
        write_run_tcl(out, project_name, top)
        (out / "README.md").write_text(
            f"# {project_name}\n\n"
            f"顶层：`{top}`\n\n"
            f"器件：`{PART}`\n\n"
            "创建工程：\n\n"
            "```tcl\n"
            "vivado -mode batch -source scripts/create_project.tcl\n"
            "```\n\n"
            "验证工程文件：\n\n"
            "```tcl\n"
            "vivado -mode batch -source scripts/validate_project.tcl\n"
            "```\n\n"
            "工程内的 RTL、初始化存储器和 250 MHz 约束均为本目录副本；MEM 文件使用唯一文件名加入 sources_1，RTL 仅引用文件名（含层名前缀）。\n",
            encoding="utf-8",
        )
        print(f"{key}: {out} rtl={len(common_rtl)+1} mem={len(copied)}")


if __name__ == "__main__":
    main()

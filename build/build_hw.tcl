# One-step build of the TX or RX bitstream from the repository sources (Vivado 2025.2).
#
#   vivado -mode batch -source build/build_hw.tcl -tclargs tx [jobs]
#   vivado -mode batch -source build/build_hw.tcl -tclargs rx [jobs]
#
# Creates a fresh project in build/work/<side> (deleted first), adds the sources listed in src/hw/<side>/files.txt,
# the IP (.xci, copied into the work directory so that no generated output lands in src/), builds the PS block
# design with src/hw/<side>/bd/create_ps_<side>_bd.tcl, then synthesis / implementation / bitstream with the Vivado
# default strategies (as the deployed build). Results in build/out/: jscc_<side>.bit, jscc_<side>.hwh (PYNQ overlay)
# and <side>_{utilization,timing,power}.rpt.

set side [lindex $argv 0]
if {$side ni {tx rx}} { error "usage: vivado -mode batch -source build/build_hw.tcl -tclargs tx|rx \[jobs\]" }
set jobs [expr {[llength $argv] > 1 ? [lindex $argv 1] : 8}]
set root [file normalize [file join [file dirname [info script]] ..]]
set src  $root/src/hw/$side
set work $root/build/work/$side
set out  $root/build/out
set part xczu5eg-sfvc784-2-e
set top  jscc_${side}_ps_top

file delete -force $work
file mkdir $work $out
create_project jscc_${side} $work -part $part
set_property target_language Verilog [current_project]

# ---- sources / constraints / IP from files.txt
set sec ""
array set files {src {} constr {} ip {}}
foreach line [split [read [set fh [open $src/files.txt r]]] "\n"] {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} continue
    if {[regexp {^\[(\w+)\]$} $line -> sec]} continue
    lappend files($sec) $line
}
close $fh
add_files -norecurse -fileset sources_1 [lmap f $files(src) {file join $src $f}]
add_files -norecurse -fileset constrs_1 [lmap f $files(constr) {file join $src $f}]
# IP: same directory depth as in the original project (sources_1/ip/<name>/<name>.xci under <project>.srcs), so that
# relative references such as ../../../../coe/<file>.coe of xcorr_cplx_block resolve to <work>/coe
if {[file isdirectory $src/coe]} { file copy -force $src/coe $work/coe }
foreach x $files(ip) {
    set name [file tail [file dirname $x]]
    set d $work/ip_srcs/sources_1/ip/$name
    file mkdir $d
    file copy -force [file join $src $x] $d/
    add_files -norecurse [file join $d [file tail $x]]
}
generate_target all [get_ips]

# ---- PS block design + wrapper
source $src/bd/create_ps_${side}_bd.tcl
generate_target all [get_files ps_${side}.bd]

set_property top $top [get_filesets sources_1]
update_compile_order -fileset sources_1

# ---- synthesis, implementation, bitstream
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
set st [get_property STATUS [get_runs impl_1]]
puts "BUILD $side: $st  WNS [get_property STATS.WNS [get_runs impl_1]]  WHS [get_property STATS.WHS [get_runs impl_1]]"
set bit [lindex [glob -nocomplain $work/jscc_${side}.runs/impl_1/*.bit] 0]
if {$bit eq ""} { error "no bitstream ($st)" }
file copy -force $bit $out/jscc_${side}.bit
file copy -force [lindex [glob $work/jscc_${side}.gen/sources_1/bd/ps_${side}/hw_handoff/*.hwh] 0] $out/jscc_${side}.hwh
open_run impl_1
report_utilization    -file $out/${side}_utilization.rpt
report_timing_summary -file $out/${side}_timing.rpt
report_power          -file $out/${side}_power.rpt
close_project
puts "OUTPUT $out/jscc_${side}.bit $out/jscc_${side}.hwh"

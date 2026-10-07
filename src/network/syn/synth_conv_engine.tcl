# Out-of-context synthesis of conv_engine for engines from runs/fpga_export_w8a12/rtl_init.
#   vivado -mode batch -source syn/synth_conv_engine.tcl -tclargs [engine ...]
set root [file normalize [file join [file dirname [info script]] ..]]
set out  [file join $root syn out]
set init [file join $root runs fpga_export_w8a12 rtl_init]
file mkdir $out

# engine -> {generics} {plan}: generated from rtl_init/<engine>/engine.json by gen_conv_configs.py
source [file join $root syn conv_configs.tcl]

set part xczu5eg-sfvc784-1-e
set wanted $argv
if {[llength $wanted] == 0} { foreach {n g e} $configs { lappend wanted $n } }

foreach {name generics expect} $configs {
    if {[lsearch -exact $wanted $name] < 0} continue
    close_project -quiet
    create_project -in_memory -part $part
    read_verilog -sv [list [file join $root rtl rom.sv] [file join $root rtl rom_banked.sv] [file join $root rtl mul_serial.sv] [file join $root rtl weight_stream.sv] [file join $root rtl conv_engine.sv]]
    auto_detect_xpm
    read_xdc [file join $root syn clk_250.xdc]
    set d [file join $init $name]
    set gargs {}
    foreach g $generics { lappend gargs -generic $g }
    foreach {k f} {WROM_PREFIX wrom BIAS_FILE bias.mem PRE_FILE pre.mem M_FILE M.mem SH_FILE sh.mem} {
        lappend gargs -generic "$k=\"[file join $d $f]\""
    }
    synth_design -top conv_engine -part $part -mode out_of_context {*}$gargs
    set tag [string map {. _ + _} $name]
    report_utilization -file [file join $out conv_$tag.util.rpt]
    report_timing_summary -file [file join $out conv_$tag.timing.rpt]
    report_ram_utilization -detail -file [file join $out conv_$tag.ram.rpt]

    set r36  [llength [get_cells -quiet -hier -filter {REF_NAME == RAMB36E2}]]
    set r18  [llength [get_cells -quiet -hier -filter {REF_NAME == RAMB18E2}]]
    set lram [llength [get_cells -quiet -hier -filter {REF_NAME =~ RAM* && REF_NAME !~ RAMB*}]]
    set dsp  [llength [get_cells -quiet -hier -filter {REF_NAME == DSP48E2}]]
    set lut  [llength [get_cells -quiet -hier -filter {REF_NAME =~ LUT*}]]
    set ff   [llength [get_cells -quiet -hier -filter {REF_NAME =~ FD*}]]
    set wns  [get_property SLACK [lindex [get_timing_paths -quiet -max_paths 1 -setup] 0]]
    puts [format "RESULT %-16s RAMB36=%d RAMB18=%d LUTRAM-cells=%d DSP=%d LUT=%d FF=%d WNS=%s ns | plan: %s" \
          $name $r36 $r18 $lram $dsp $lut $ff $wns $expect]
}

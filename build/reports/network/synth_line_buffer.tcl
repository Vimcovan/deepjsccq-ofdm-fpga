# Out-of-context synthesis of axis_line_buffer for configurations taken from docs/memory_plan.md.
#   vivado -mode batch -source syn/synth_line_buffer.tcl -tclargs <config> [<config> ...]
# Prints one RESULT line per configuration and writes reports to syn/out/.
set root [file normalize [file join [file dirname [info script]] ..]]
set out  [file join $root syn out]
file mkdir $out

# name -> generics (from docs/memory_plan.md) and the mapping the plan expects
set configs {
    enc1_conv1_uram  {W=128 H=128 C=32 DATA_W=12 PACK=6 GROUPS=1 RAM_STYLE="ultra"}  {1 URAM}
    enc1_conv1_block {W=128 H=128 C=32 DATA_W=12 PACK=6 GROUPS=1 RAM_STYLE="block"}  {4 BRAM36 (512x72)}
    enc2_conv2       {W=64  H=64  C=32 DATA_W=12 PACK=3 GROUPS=3 RAM_STYLE="block"}  {2048x36 -> 2 BRAM36 (4 BRAM18)}
    dec0_a0          {W=64  H=64  C=8  DATA_W=12 PACK=3 GROUPS=8 RAM_STYLE="block"}  {512x36 -> 1 BRAM18}
    enc0_conv1       {W=256 H=256 C=3  DATA_W=8  PACK=1 GROUPS=2 STRIDE=2 RAM_STYLE="block"} {2304x8 -> 1 BRAM36}
}

set part xczu5eg-sfvc784-1-e
if {[llength [get_parts -quiet $part]] == 0} { set part [lindex [get_parts -quiet xczu5eg*] 0] }
puts "PART $part"

set wanted $argv
if {[llength $wanted] == 0} { foreach {n g e} $configs { lappend wanted $n } }

foreach {name generics expect} $configs {
    if {[lsearch -exact $wanted $name] < 0} continue
    close_project -quiet
    create_project -in_memory -part $part
    read_verilog -sv [list [file join $root rtl sdp_ram.sv] [file join $root rtl axis_line_buffer.sv]]
    read_xdc [file join $root syn clk_250.xdc]
    set gargs {}
    foreach g $generics { lappend gargs -generic $g }
    synth_design -top axis_line_buffer -part $part -mode out_of_context -flatten_hierarchy rebuilt {*}$gargs
    report_utilization -file [file join $out $name.util.rpt]
    report_utilization -hierarchical -file [file join $out $name.util_hier.rpt]
    report_timing_summary -file [file join $out $name.timing.rpt]
    report_ram_utilization -file [file join $out $name.ram.rpt]

    set r36  [llength [get_cells -quiet -hier -filter {REF_NAME == RAMB36E2}]]
    set r18  [llength [get_cells -quiet -hier -filter {REF_NAME == RAMB18E2}]]
    set ur   [llength [get_cells -quiet -hier -filter {REF_NAME == URAM288}]]
    set lram [llength [get_cells -quiet -hier -filter {REF_NAME =~ RAM* && REF_NAME !~ RAMB*}]]
    set dsp  [llength [get_cells -quiet -hier -filter {REF_NAME == DSP48E2}]]
    set lut  [llength [get_cells -quiet -hier -filter {REF_NAME =~ LUT*}]]
    set ff   [llength [get_cells -quiet -hier -filter {REF_NAME =~ FD*}]]
    set wns  [get_property SLACK [lindex [get_timing_paths -quiet -max_paths 1 -setup] 0]]
    puts [format "RESULT %-17s RAMB36=%d RAMB18=%d URAM=%d LUTRAM-cells=%d DSP=%d LUT=%d FF=%d WNS=%s ns | plan: %s" \
          $name $r36 $r18 $ur $lram $dsp $lut $ff $wns $expect]
}

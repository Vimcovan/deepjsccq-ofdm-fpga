# SSCC TX -> AWGN -> RX simulation (xsim). Usage: vivado -mode batch -source run_sim.tcl -tclargs "<plusargs>"
set d [file normalize [file dirname [info script]]]
set hw [file normalize [file join $d .. .. src hw]]   ;# sscc_tx.sv (tx/rtl/ps), sscc_rx.sv + Viterbi IP (rx)
set plus [string map {: =} [join $argv " "]]   ;# cmd.exe splits at "=": pass NAME:value
if {![file exists $d/prj/sscc_sim.xpr]} {
    create_project sscc_sim $d/prj -part xczu5eg-sfvc784-2-e
    file mkdir $d/prj/ip/viterbi; file copy -force $hw/rx/ip/viterbi/viterbi.xci $d/prj/ip/viterbi/
    add_files -norecurse $d/prj/ip/viterbi/viterbi.xci
    generate_target {simulation synthesis} [get_files viterbi.xci]
    add_files -norecurse [list $hw/tx/rtl/ps/sscc_tx.sv $hw/rx/rtl/ps/sscc_rx.sv]
    add_files -fileset sim_1 -norecurse $d/tb_sscc.sv
    set_property top tb_sscc [get_filesets sim_1]
    set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
} else {
    open_project $d/prj/sscc_sim.xpr
}
update_compile_order -fileset sim_1
set opts ""
foreach p $plus { append opts " -testplusarg $p" }
set_property -name {xsim.simulate.xsim.more_options} -value $opts -objects [get_filesets sim_1]
# HARD:1 -> compile with SSCC_HARD (hard-decision Viterbi input, to see what the soft information gains)
set_property -name {xsim.compile.xvlog.more_options} -value [expr {[string match *HARD=1* $plus] ? "-d SSCC_HARD" : ""}] -objects [get_filesets sim_1]
launch_simulation
close_sim
close_project

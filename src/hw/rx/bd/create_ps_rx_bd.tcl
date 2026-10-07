# Block design ps_rx for OFDM_JSCC_PS_RX (run inside the open project).
#   PS (PYNQ-ZU config) + img_dma (S2MM: decoded image) + cap_dma (S2MM: raw ADC capture, via 4K FIFO)
#   control: HPM0_LPD -> SmartConnect -> img_dma / cap_dma S_AXI_LITE, M_AXI_REG (AXI4-Lite), M_AXI_TEL (AXI4)
#   data:    img_dma / cap_dma M_AXI_S2MM -> SmartConnect -> HP0_FPD
#   everything on the external aclk (= clk_100M of the PL MMCM), external aresetn
# PS (PYNQ-ZU) configuration: src/hw/ps_config_list.txt unless the caller set ps_cfg_file
if {![info exists ps_cfg_file]} { set ps_cfg_file [file normalize [file join [file dirname [info script]] .. .. ps_config_list.txt]] }
catch {delete_bd_objs [get_bd_cells *]}
create_bd_design ps_rx

#---- PS
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e ps_e_0]
set fh [open $ps_cfg_file r]; set lines [split [read $fh] "\n"]; close $fh
set cfg {}
foreach l $lines { if {$l ne ""} { lappend cfg [lindex $l 0] [lindex $l 1] } }
set_property -dict $cfg $ps
set_property -dict [list CONFIG.PSU__USE__M_AXI_GP0 0 CONFIG.PSU__USE__M_AXI_GP1 0 CONFIG.PSU__USE__M_AXI_GP2 1 \
    CONFIG.PSU__USE__S_AXI_GP2 1 CONFIG.PSU__USE__S_AXI_GP4 0 CONFIG.PSU__USE__S_AXI_GP6 0 \
    CONFIG.PSU__FPGA_PL0_ENABLE 1 CONFIG.PSU__FPGA_PL1_ENABLE 0 CONFIG.PSU__FPGA_PL2_ENABLE 0 CONFIG.PSU__FPGA_PL3_ENABLE 0 \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ 100 CONFIG.PSU__USE__IRQ0 1] $ps

#---- external ports
set aclk [create_bd_port -dir I -type clk -freq_hz 100000000 aclk]
set aresetn [create_bd_port -dir I -type rst aresetn]
set_property CONFIG.POLARITY ACTIVE_LOW $aresetn
create_bd_port -dir O -type rst pl_resetn0
connect_bd_net [get_bd_pins ps_e_0/pl_resetn0] [get_bd_ports pl_resetn0]
foreach n {S_AXIS_IMG S_AXIS_CAP} {
    set p [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 $n]
    set_property -dict [list CONFIG.TDATA_NUM_BYTES 4 CONFIG.HAS_TLAST 1 CONFIG.HAS_TKEEP 0 CONFIG.HAS_TSTRB 0 \
        CONFIG.HAS_TREADY 1 CONFIG.TUSER_WIDTH 0 CONFIG.TID_WIDTH 0 CONFIG.TDEST_WIDTH 0 CONFIG.FREQ_HZ 100000000] $p
}
set preg [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_REG]
set_property -dict [list CONFIG.PROTOCOL AXI4LITE CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 32 CONFIG.HAS_PROT 0 CONFIG.FREQ_HZ 100000000] $preg
set ptel [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_TEL]
set_property -dict [list CONFIG.PROTOCOL AXI4 CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 32 CONFIG.ID_WIDTH 0 \
    CONFIG.HAS_BURST 1 CONFIG.HAS_CACHE 0 CONFIG.HAS_LOCK 0 CONFIG.HAS_PROT 0 CONFIG.HAS_QOS 0 CONFIG.HAS_REGION 0 \
    CONFIG.HAS_WSTRB 1 CONFIG.HAS_BRESP 1 CONFIG.HAS_RRESP 1 CONFIG.FREQ_HZ 100000000 \
    CONFIG.MAX_BURST_LENGTH 256 CONFIG.NUM_READ_OUTSTANDING 1 CONFIG.NUM_WRITE_OUTSTANDING 1] $ptel
set_property CONFIG.ASSOCIATED_BUSIF {S_AXIS_IMG:S_AXIS_CAP:M_AXI_REG:M_AXI_TEL} $aclk
set_property CONFIG.ASSOCIATED_RESET {aresetn} $aclk

#---- DMAs (S2MM only, simple mode)
foreach d {img_dma cap_dma} {
    set c [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma $d]
    set_property -dict [list CONFIG.c_include_sg 0 CONFIG.c_sg_length_width 26 CONFIG.c_include_mm2s 0 \
        CONFIG.c_include_s2mm 1 CONFIG.c_s2mm_burst_size 64 CONFIG.c_m_axi_s2mm_data_width 32] $c
}
set cf [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo cap_fifo]
set_property -dict [list CONFIG.FIFO_DEPTH 4096] $cf
connect_bd_intf_net [get_bd_intf_ports S_AXIS_IMG] [get_bd_intf_pins img_dma/S_AXIS_S2MM]
connect_bd_intf_net [get_bd_intf_ports S_AXIS_CAP] [get_bd_intf_pins cap_fifo/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins cap_fifo/M_AXIS] [get_bd_intf_pins cap_dma/S_AXIS_S2MM]

#---- interconnects
set sc_ctl [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_ctl]
set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 4] $sc_ctl
connect_bd_intf_net [get_bd_intf_pins ps_e_0/M_AXI_HPM0_LPD] [get_bd_intf_pins sc_ctl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M00_AXI] [get_bd_intf_pins img_dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M01_AXI] [get_bd_intf_pins cap_dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M02_AXI] [get_bd_intf_ports M_AXI_REG]
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M03_AXI] [get_bd_intf_ports M_AXI_TEL]
set sc_mem [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_mem]
set_property -dict [list CONFIG.NUM_SI 2 CONFIG.NUM_MI 1] $sc_mem
connect_bd_intf_net [get_bd_intf_pins img_dma/M_AXI_S2MM] [get_bd_intf_pins sc_mem/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins cap_dma/M_AXI_S2MM] [get_bd_intf_pins sc_mem/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_mem/M00_AXI] [get_bd_intf_pins ps_e_0/S_AXI_HP0_FPD]

#---- clocks / resets
connect_bd_net [get_bd_ports aclk] [get_bd_pins ps_e_0/maxihpm0_lpd_aclk] [get_bd_pins ps_e_0/saxihp0_fpd_aclk] \
    [get_bd_pins img_dma/s_axi_lite_aclk] [get_bd_pins img_dma/m_axi_s2mm_aclk] \
    [get_bd_pins cap_dma/s_axi_lite_aclk] [get_bd_pins cap_dma/m_axi_s2mm_aclk] \
    [get_bd_pins cap_fifo/s_axis_aclk] [get_bd_pins sc_ctl/aclk] [get_bd_pins sc_mem/aclk]
connect_bd_net [get_bd_ports aresetn] [get_bd_pins img_dma/axi_resetn] [get_bd_pins cap_dma/axi_resetn] \
    [get_bd_pins cap_fifo/s_axis_aresetn] [get_bd_pins sc_ctl/aresetn] [get_bd_pins sc_mem/aresetn]

#---- interrupts
set cc [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat irq_concat]
set_property CONFIG.NUM_PORTS 2 $cc
connect_bd_net [get_bd_pins img_dma/s2mm_introut] [get_bd_pins irq_concat/In0]
connect_bd_net [get_bd_pins cap_dma/s2mm_introut] [get_bd_pins irq_concat/In1]
connect_bd_net [get_bd_pins irq_concat/dout] [get_bd_pins ps_e_0/pl_ps_irq0]

#---- addresses (HPM0_LPD window 0x8000_0000)
assign_bd_address -offset 0x80000000 -range 64K [get_bd_addr_segs img_dma/S_AXI_LITE/Reg]
assign_bd_address -offset 0x80010000 -range 64K [get_bd_addr_segs cap_dma/S_AXI_LITE/Reg]
assign_bd_address -offset 0x80020000 -range 64K [get_bd_addr_segs M_AXI_REG/Reg]
assign_bd_address -offset 0x80040000 -range 256K [get_bd_addr_segs M_AXI_TEL/Reg]
assign_bd_address
validate_bd_design
save_bd_design
set w [make_wrapper -files [get_files ps_rx.bd] -top]
add_files -norecurse $w
foreach a [get_bd_addr_segs -of [get_bd_addr_spaces ps_e_0/Data]] { puts "ADDR [get_property NAME $a] [format 0x%X [get_property OFFSET $a]] [get_property RANGE $a]" }
puts "WRAPPER $w"

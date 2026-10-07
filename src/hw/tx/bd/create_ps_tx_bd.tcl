# Block design ps_tx for OFDM_JSCC_PS_TX (run inside the open project).
#   PS (PYNQ-ZU config) + img_dma (S2MM: decoded image) + cap_dma (S2MM: raw ADC capture, via 4K FIFO)
#   control: HPM0_LPD -> SmartConnect -> img_dma / cap_dma S_AXI_LITE, M_AXI_REG (AXI4-Lite), M_AXI_TEL (AXI4)
#   data:    img_dma / cap_dma M_AXI_S2MM -> SmartConnect -> HP0_FPD
#   everything on the external aclk (= clk_100M of the PL MMCM), external aresetn
# PS (PYNQ-ZU) configuration: src/hw/ps_config_list.txt unless the caller set ps_cfg_file
if {![info exists ps_cfg_file]} { set ps_cfg_file [file normalize [file join [file dirname [info script]] .. .. ps_config_list.txt]] }
catch {delete_bd_objs [get_bd_cells *]}
create_bd_design ps_tx

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
set p [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 M_AXIS_IMG]
set_property -dict [list CONFIG.FREQ_HZ 100000000] $p
set preg [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_REG]
set_property -dict [list CONFIG.PROTOCOL AXI4LITE CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 32 CONFIG.HAS_PROT 0 CONFIG.FREQ_HZ 100000000] $preg
set_property CONFIG.ASSOCIATED_BUSIF {M_AXIS_IMG:M_AXI_REG} $aclk
set_property CONFIG.ASSOCIATED_RESET {aresetn} $aclk

#---- DMA (MM2S only, simple mode)
set c [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma img_dma]
set_property -dict [list CONFIG.c_include_sg 0 CONFIG.c_sg_length_width 26 CONFIG.c_include_mm2s 1     CONFIG.c_include_s2mm 0 CONFIG.c_m_axis_mm2s_tdata_width 32 CONFIG.c_mm2s_burst_size 64 CONFIG.c_m_axi_mm2s_data_width 32] $c
connect_bd_intf_net [get_bd_intf_pins img_dma/M_AXIS_MM2S] [get_bd_intf_ports M_AXIS_IMG]

#---- interconnects
set sc_ctl [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_ctl]
set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 2] $sc_ctl
connect_bd_intf_net [get_bd_intf_pins ps_e_0/M_AXI_HPM0_LPD] [get_bd_intf_pins sc_ctl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M00_AXI] [get_bd_intf_pins img_dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M01_AXI] [get_bd_intf_ports M_AXI_REG]
set sc_mem [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_mem]
set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 1] $sc_mem
connect_bd_intf_net [get_bd_intf_pins img_dma/M_AXI_MM2S] [get_bd_intf_pins sc_mem/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_mem/M00_AXI] [get_bd_intf_pins ps_e_0/S_AXI_HP0_FPD]

#---- clocks / resets
connect_bd_net [get_bd_ports aclk] [get_bd_pins ps_e_0/maxihpm0_lpd_aclk] [get_bd_pins ps_e_0/saxihp0_fpd_aclk]     [get_bd_pins img_dma/s_axi_lite_aclk] [get_bd_pins img_dma/m_axi_mm2s_aclk] [get_bd_pins sc_ctl/aclk] [get_bd_pins sc_mem/aclk]
connect_bd_net [get_bd_ports aresetn] [get_bd_pins img_dma/axi_resetn] [get_bd_pins sc_ctl/aresetn] [get_bd_pins sc_mem/aresetn]

#---- interrupts
set cc [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat irq_concat]
set_property CONFIG.NUM_PORTS 1 $cc
connect_bd_net [get_bd_pins img_dma/mm2s_introut] [get_bd_pins irq_concat/In0]
connect_bd_net [get_bd_pins irq_concat/dout] [get_bd_pins ps_e_0/pl_ps_irq0]

#---- addresses (HPM0_LPD window 0x8000_0000)
assign_bd_address -offset 0x80000000 -range 64K [get_bd_addr_segs img_dma/S_AXI_LITE/Reg]
assign_bd_address -offset 0x80020000 -range 64K [get_bd_addr_segs M_AXI_REG/Reg]
assign_bd_address
validate_bd_design
save_bd_design
set w [make_wrapper -files [get_files ps_tx.bd] -top]
add_files -norecurse $w
foreach a [get_bd_addr_segs -of [get_bd_addr_spaces ps_e_0/Data]] { puts "ADDR [get_property NAME $a] [format 0x%X [get_property OFFSET $a]] [get_property RANGE $a]" }
puts "WRAPPER $w"

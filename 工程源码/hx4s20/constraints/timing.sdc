# Board reference oscillator: 50 MHz.
create_clock -name clk -period 20.000 -waveform {0.000 10.000} [get_ports {clk}]

# Define PLL outputs as generated clocks, rather than independent primary
# clocks on a network already driven by clk. Ratios/phases match the IP files.
# sys_pll: C0=100 MHz feedback, C1/C2=41.666667 MHz/0/180 deg,
# C3=62.5 MHz SD/scaler. The VCO and feedback configuration are unchanged.
create_generated_clock -name sys_feedback_clk -source [get_ports {clk}] \
    -master_clock clk -multiply_by 2.000 -phase 0 \
    [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
create_generated_clock -name sd_card_clk -source [get_ports {clk}] \
    -master_clock clk -multiply_by 1.250 -phase 0 \
    [get_pins {sys_pll_m0/pll_inst.clkc[3]}]
create_generated_clock -name ext_mem_clk -source [get_ports {clk}] \
    -master_clock clk -divide_by 1.200 -phase 0 \
    [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
create_generated_clock -name ext_mem_clk_sft -source [get_ports {clk}] \
    -master_clock clk -divide_by 1.200 -phase 180 \
    [get_pins {sys_pll_m0/pll_inst.clkc[2]}]

# video_pll: C0=25 MHz/0 deg, C1=125 MHz/0 deg. These clocks run together;
# retain their timing relationship for the 10:1 TMDS serializer.
create_generated_clock -name video_clk -source [get_ports {clk}] \
    -master_clock clk -divide_by 2.000 -phase 0 \
    [get_pins {video_pll_m0/pll_inst.clkc[0]}]
create_generated_clock -name hdmi_5x_clk -source [get_ports {clk}] \
    -master_clock clk -multiply_by 2.500 -phase 0 \
    [get_pins {video_pll_m0/pll_inst.clkc[1]}]

# PLL_HDMI_AUDIO: 750 MHz VCO / 61 = 12.295081967 MHz.
# The exact reference-to-output divider is 61/15 (period 81.333333 ns).
create_generated_clock -name audio_mclk -source [get_ports {clk}] \
    -master_clock clk -divide_by 4.066666667 -phase 0 \
    [get_pins {u_audio_pll/pll_inst.clkc[2]}]

# Independent PLL domains exchange data through CDC synchronizers/FIFOs.
# Preserve timing between clk and sys_pll, within the SDRAM 0/180-deg pair,
# and between pixel/serializer clocks. No same-PLL paths are cut.
set_clock_groups -asynchronous \
    -group [get_clocks {clk sys_feedback_clk sd_card_clk ext_mem_clk ext_mem_clk_sft}] \
    -group [get_clocks {video_clk hdmi_5x_clk}] \
    -group [get_clocks {audio_mclk}]

set_false_path -from [get_ports {link_rx}]

set_false_path -from [get_ports {music_return}]

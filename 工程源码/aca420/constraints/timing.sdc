create_clock -name board_clk -period 20.000 [get_ports {clk}]
# Vendor PLL: 750 MHz VCO / 61; actual Fs=48027.663934 Hz.
create_generated_clock -name audio_feedback -source [get_ports {clk}] \
    -master_clock board_clk -multiply_by 1.5 [get_pins {u_pll/pll_inst.clkc[0]}]
create_generated_clock -name audio_mclk -source [get_ports {clk}] \
    -master_clock board_clk -divide_by 4.066666667 [get_pins {u_pll/pll_inst.clkc[2]}]
# Between these domains all paths use reset release, two-FF synchronizers or
# the documented stable-data/toggle PCM mailbox. No raw audio pulse crosses.
set_clock_groups -asynchronous \
    -group [get_clocks {board_clk audio_feedback}] -group [get_clocks {audio_mclk}]
# ADC changes on falling BCLK. The enabled negative-MCLK-edge input register
# samples 1.5 MCLK periods later (122 ns), before the next BCLK rise.
# Zero minimum assumes no guaranteed codec clock-to-out minimum. 60 ns maximum
# includes codec/board skew budget and must be checked on hardware.
create_generated_clock -name audio_bclk -source [get_pins {u_pll/pll_inst.clkc[2]}] \
    -master_clock audio_mclk -divide_by 4 [get_ports {I2S_BCLK}]
set_input_delay -clock audio_bclk -clock_fall -max 60.000 [get_ports {I2S_DI}]
set_input_delay -clock audio_bclk -clock_fall -min 0.000 [get_ports {I2S_DI}]
# Enable excludes the first negative MCLK edge after BCLK fall.
set_multicycle_path 2 -setup -from [get_ports {I2S_DI}]
set_multicycle_path 1 -hold -from [get_ports {I2S_DI}]
# User-operated controls are asynchronous and enter synchronizers/reset trees.
set_false_path -from [get_ports {reset_n key_monitor_n}]

set_false_path -from [get_ports {key_slot_n key_learn_n key_demo_n link_rx}]

set_false_path -from [get_ports {music_bclk music_lrck music_in}]

`timescale 1ns/1ps
module tb_sw4_debounce;
reg clk=0,video=0,rst=1,sw4=1,frame=0;
always #10 clk=~clk;
always #7 video=~video;
top #(.SWITCH_DEBOUNCE_CYCLES(8)) dut(.clk(clk),.key1(1'b1),.key2(1'b1),.key3(1'b1),.key4(1'b1),
 .sw1(1'b1),.sw2(1'b1),.sw3(1'b1),.sw4(sw4),.sd_miso(1'b1),.link_rx(1'b1),.music_return(1'b0));
task cycles;input integer n;begin repeat(n)@(negedge clk);end endtask
task boundary;begin @(negedge video);frame=1;@(negedge video);frame=0;@(negedge video);end endtask
task check_layers;input expected;begin
 if(dut.osd_frame_enable!==expected || dut.u_osd_overlay.I_osd_en!==expected ||
    dut.u_osd_status_overlay.I_osd_en!==expected || dut.u_mic_overlay.enable!==expected)
   $fatal(1,"overlay layers not synchronized expected=%b",expected);
end endtask
initial begin
 force dut.rst_all=rst;force dut.rst_sd=rst;force dut.video_clk=video;
 force dut.sd_card_clk=clk;force dut.ext_mem_clk=clk;force dut.ext_mem_clk_sft=clk;force dut.audio_mclk=1'b0;
 force dut.transition_frame_start=frame;
 cycles(6);rst=0;cycles(10);boundary;check_layers(0);
 // Bounce on both edges; short pulses must not reach any text layer.
 sw4=0;cycles(2);sw4=1;cycles(4);sw4=0;cycles(2);sw4=1;cycles(12);boundary;check_layers(0);
 sw4=0;cycles(7);boundary;check_layers(0);cycles(10);check_layers(0);
 if(!dut.osd_db)$fatal(1,"stable ON did not pass debounce");
 boundary;check_layers(1);
 sw4=1;cycles(2);sw4=0;cycles(5);sw4=1;cycles(2);sw4=0;cycles(12);boundary;check_layers(1);
 sw4=1;cycles(18);check_layers(1);
 if(dut.osd_db)$fatal(1,"stable OFF did not pass debounce");
 boundary;check_layers(0);
 sw4=0;cycles(18);boundary;check_layers(1);
 rst=1;cycles(3);check_layers(0);rst=0;cycles(18);check_layers(0);boundary;check_layers(1);
 $display("PASS standalone SW4 debounce: actual integrated top, asynchronous clocks, ON/OFF bounce rejection, 8-cycle stable threshold, all three OSD layers at frame boundary, reset while ON");$finish;
end
initial begin #100000;$fatal(1,"SW4 test timeout");end
endmodule

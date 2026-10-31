`timescale 1ns/1ps
module tb_audio_visual_link;
reg clk=0,rst=1,en=0,frame=0,valid=0,overflow=0;
reg [2:0] peak=0;
reg [31:0] power=10000;
wire start;
integer events=0;
always #5 clk=~clk;
always @(negedge clk) if(start) events=events+1;
audio_visual_link #(.INDEX_WIDTH(3),.COOLDOWN_FRAMES(3)) dut(.clk(clk),.rst(rst),.enable(en),
 .frame_start(frame),.result_valid(valid),.result_overflow(overflow),
 .peak_index(peak),.peak_power(power),.transition_start(start));
task result;input [2:0] p;begin @(negedge clk);peak=p;valid=1;@(negedge clk);valid=0;@(negedge clk);end endtask
task frames;input integer n;integer k;begin for(k=0;k<n;k=k+1) begin @(negedge clk);frame=1;@(negedge clk);frame=0;end @(negedge clk);end endtask
initial begin
 repeat(3) @(negedge clk);rst=0;
 result(0);result(0);result(0);if(events) $fatal(1,"disabled link emitted event");
 en=1;result(0);result(1);result(0);if(events) $fatal(1,"unstable peak emitted event");
 result(0);result(0);if(events!=0 || !dut.have_peak) $fatal(1,"first stable peak must establish baseline without event");
 result(0);result(0);if(events!=0) $fatal(1,"same tone repeated event");
 result(7);result(7);result(7);if(events!=1) $fatal(1,"changed stable high-band tone missing");
 result(1);result(1);result(1);if(events!=1) $fatal(1,"cooldown not respected");
 frames(3);result(1);if(events!=2) $fatal(1,"new tone not emitted after cooldown");
 frames(3);overflow=1;result(3);result(3);result(3);if(events!=2) $fatal(1,"clipped result emitted event");
 overflow=0;power=0;result(3);result(3);result(3);if(events!=2) $fatal(1,"silence emitted event");
 en=0;@(negedge clk);en=1;power=10000;result(3);result(3);result(3);
 if(events!=2 || !dut.have_peak) $fatal(1,"re-enable must establish baseline without changing image");
 result(0);result(0);result(0);if(events!=3) $fatal(1,"changed tone after re-enable missing");
 rst=1;@(negedge clk);if(start || dut.have_peak || dut.cooldown) $fatal(1,"reset failure");
 $display("PASS audio visual link: stable windows, jitter/silence rejection, cooldown, re-enable and reset");$finish;
end
initial begin #20000;$fatal(1,"visual link timeout");end
endmodule

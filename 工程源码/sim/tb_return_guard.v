`timescale 1ns/1ps
module tb_return_guard;
reg clk=0,rst=1,lrck=0,data=0,request=1;
wire present,route;
always #5 clk=~clk;
music_return_guard #(.IDLE_CYCLES(40)) dut(.clk(clk),.rst(rst),.lrck(lrck),
 .return_data(data),.requested(request),.present(present),.route(route));
task cycles;input integer n;begin repeat(n)@(negedge clk);end endtask
task boundary;begin lrck=1;cycles(2);lrck=0;cycles(2);end endtask
integer i;
initial begin
 cycles(3);rst=0;cycles(50);boundary;
 if(present || route)$fatal(1,"disconnected return selected");
 for(i=0;i<5;i=i+1)begin data=~data;cycles(3);end
 if(!present || route)$fatal(1,"route changed before stereo boundary");
 boundary;if(!route)$fatal(1,"valid return not selected");
 cycles(45);if(present || !route)$fatal(1,"loss timeout/boundary failure");
 boundary;if(route)$fatal(1,"stuck return did not fall back to local audio");
 data=~data;cycles(5);boundary;if(!route)$fatal(1,"return did not recover");
 request=0;boundary;if(route)$fatal(1,"bypass request ignored");
 $display("PASS return guard: disconnected/stuck data uses local audio, live return recovers, stereo-boundary routing");$finish;
end
endmodule

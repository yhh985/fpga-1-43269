`timescale 1ns/1ps
// Exhaustively compare the narrowed text arithmetic with the previous layer
// across every overlay coordinate, all command strings and operating states.
module tb_zoom_overlay_equivalence;
reg clk=0,rst=0,enable=1,online=1,de=1;reg [255:0] status=0;
reg [23:0] rgb=24'h123456;wire [23:0] actual,expected;
integer s,xx,yy,checks=0;
mic_overlay dut(.clk(clk),.rst(rst),.vs(1'b1),.de(de),.enable(enable),.online(online),.status(status),.rgb(rgb),.out_rgb(actual));
mic_overlay_reference reference(.clk(clk),.rst(rst),.vs(1'b1),.de(de),.enable(enable),.online(online),.status(status),.rgb(rgb),.out_rgb(expected));
initial begin
 for(s=0;s<16;s=s+1)begin
  status={$random,$random,$random,$random,$random,$random,$random,$random};
  status[23]=s<8;status[25:24]=s%4;status[15:14]=s/4;
  online=s!=14;enable=s!=15;
  for(yy=140;yy<380;yy=yy+1)begin
   for(xx=0;xx<256;xx=xx+1)begin
    force dut.x=xx;force reference.x=xx;force dut.y=yy;force reference.y=yy;
    #1;if(actual!==expected)$fatal(1,"overlay changed state=%0d x=%0d y=%0d actual=%h expected=%h",s,xx,yy,actual,expected);
    checks=checks+1;
   end
  end
 end
 $display("PASS overlay arithmetic equivalence: %0d pixels, all command/mode strings, bars, wave, offline and disabled",checks);$finish;
end
endmodule

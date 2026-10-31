`timescale 1ns/1ps
module tb_snapshot;
 reg a=0,b=0,rst=1,valid=0,frame=0;reg [256:0] data=0;wire [256:0] out;
 always #5 a=~a;always #7 b=~b;
 link_snapshot_cdc dut(.source_clk(a),.dest_clk(b),.rst(rst),.source_valid(valid),.source_data(data),.frame_start(frame),.dest_data(out));
 task send;input [256:0] value;begin wait(dut.ack_sync[1]==dut.request);@(negedge a);data=value;valid=1;@(negedge a);valid=0;repeat(10)@(negedge b);end endtask
 initial begin
  #30;rst=0;send(257'h123456);if(out!=0)$fatal(1,"changed mid frame");
  @(negedge b);frame=1;@(negedge b);frame=0;if(out!=257'h123456)$fatal(1,"frame commit");
  send(257'habcdef);if(out!=257'h123456)$fatal(1,"mid frame second");
  @(negedge b);frame=1;@(negedge b);frame=0;if(out!=257'habcdef)$fatal(1,"second commit");
  // Backpressure: source changing while busy cannot tear the held mailbox.
  send(257'h111122223333);data=257'hdeadbeef;valid=1;
  repeat(8)@(negedge b);valid=0;
  if(out!=257'habcdef)$fatal(1,"busy update changed mid-frame");
  @(negedge b);frame=1;@(negedge b);frame=0;
  if(out!=257'h111122223333)$fatal(1,"source mailbox not held");
  send(257'h444455556666);
  @(negedge b);frame=1;@(negedge b);frame=0;
  if(out!=257'h444455556666)$fatal(1,"mailbox did not rearm");
  $display("PASS snapshot CDC: unrelated clocks, stable mailbox, frame-boundary commits");$finish;
 end
endmodule

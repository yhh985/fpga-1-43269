`timescale 1ns/1ps
module tb_feature_report;
 reg clk=0,rst=1,fv=0,done=0;reg [3:0] fi=0;reg signed [7:0] fd=0;
 always #10 clk=~clk;
 wire tx,valid,framing,overrun;wire [7:0] data;
 reg [7:0] flags=8'h4d;
 reg [287:0] logits;
 aca_feature_report #(.CLOCK_HZ(1600000),.BAUD(100000)) dut(.clk(clk),.rst_n(!rst),
  .feature_valid(fv),.feature_index(fi),.feature_data(fd),.frame_done(done),.flags(flags),
  .reject_flags(8'h60),.debug_sequence(16'h1234),.debug_voiced(7'd13),.debug_duration(7'd22),
  .debug_logits(logits),.engine_state(8'h03),.peak(16'h7654),.noise(16'h3210),.sample_count(16'hfedc),.tx(tx));
 uart_rx rx(.clk(clk),.rst(rst),.rxd(tx),.prescale(16'd2),.m_axis_tdata(data),
  .m_axis_tvalid(valid),.m_axis_tready(1'b1),.frame_error(framing),.overrun_error(overrun));
 reg [7:0] got[0:221];integer count=0,i,j;reg [15:0] crc;
 always @(posedge clk)if(valid)begin got[count]=data;count=count+1;end
 task frame;input integer base;begin
  for(i=0;i<16;i=i+1)begin @(negedge clk);fv=1;fi=i;fd=base+i;done=i==15;end
  @(negedge clk);fv=0;done=0;repeat(4)@(negedge clk);
 end endtask
 task check_packet;input integer start,sequence_value,base,flag_value,drop;begin
  if(got[start]!==8'ha5 || got[start+1]!==8'h5a || got[start+2]!==8'h52)$fatal(1,"header");
  if(got[start+3]!==sequence_value || got[start+4]!==0 || got[start+5]!==flag_value)$fatal(1,"snapshot/sequence");
  for(i=0;i<16;i=i+1)if(got[start+12+i]!==base+i)$fatal(1,"feature including last band %0d",i);
  if(got[start+6]!==8'h60 || got[start+7]!==13 || got[start+8]!==22 || got[start+9]!==8'h34 || got[start+10]!==8'h12)$fatal(1,"reject metadata");
  for(i=0;i<36;i=i+1)if(got[start+28+i]!==i)$fatal(1,"logit snapshot %0d",i);
  if(got[start+64]!==8'h54 || got[start+65]!==8'h76 || got[start+71]!==drop)$fatal(1,"PCM metadata/drop");
  crc=16'hffff;
  for(i=0;i<72;i=i+1)begin
   crc=crc^{got[start+i],8'd0};
   for(j=0;j<8;j=j+1)crc=crc[15]?(crc<<1)^16'h1021:crc<<1;
  end
  if({got[start+73],got[start+72]}!==crc)$fatal(1,"CRC16");
 end endtask
 initial begin
  for(i=0;i<36;i=i+1)logits[i*8+:8]=i;
  repeat(4)@(negedge clk);rst=0;frame(10);
  flags=8'h99; // Must not alter a packet already admitted.
  wait(count==74);repeat(30)@(negedge clk);check_packet(0,1,10,8'h4d,0);
  frame(30);frame(50); // Deliberate overrun: second incoming frame is dropped.
  wait(count==148);repeat(30)@(negedge clk);check_packet(74,2,30,8'h99,0);
  frame(70);wait(count==222);repeat(30)@(negedge clk);check_packet(148,4,70,8'h99,1);
  if(framing || overrun)$fatal(1,"UART framing/consumer");
  $display("PASS feature UART: complete frames, last-band alignment, immutable snapshots, CRC16, sequence/drop detection");$finish;
 end
 initial begin #20000000;$fatal(1,"watchdog count=%0d",count);end
endmodule

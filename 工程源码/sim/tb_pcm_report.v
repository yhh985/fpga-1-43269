`timescale 1ns/1ps
module tb_pcm_report;
 reg clk=0,rst=1,pv=0,fv=0,done=0;
 reg signed [15:0] pcm=0;reg [3:0] fi=0;reg signed [7:0] fd=0;
 reg [7:0] flags=8'h4d;reg [63:0] trace=64'h0103000200031234;
 always #10 clk=~clk;
 wire tx,valid;wire [7:0] data;
 aca_pcm_feature_report #(.CLOCK_HZ(1600000),.BAUD(100000)) dut(
 .clk(clk),.rst_n(!rst),.pcm_valid(pv),.pcm(pcm),.feature_valid(fv),.frame_done(done),
 .feature_index(fi),.feature_data(fd),.flags(flags),.reject_flags(8'h20),
 .debug_sequence(16'h1234),.peak(16'd0),.noise(16'd0),.sample_count(16'd0),
 .debug_voiced(7'd20),.debug_duration(7'd30),.debug_logits(288'd0),
 .engine_state(8'h03),.command_trace(trace),.tx(tx));
 uart_rx rx(.clk(clk),.rst(rst),.rxd(tx),.prescale(16'd2),.m_axis_tdata(data),
 .m_axis_tvalid(valid),.m_axis_tready(1'b1));
 reg [7:0] got[0:1787];integer count=0,k,j,c,out;
 always @(posedge clk)if(valid)begin
  if(count>=1788)$fatal(1,"unexpected packet");
  got[count]=data;count=count+1;
 end
 task frame;input integer base,spacing;integer n;begin
  for(n=0;n<256;n=n+1)begin
   @(negedge clk);pv=1;pcm=base+n*97;
   if(n>=240)begin fv=1;fi=n-240;fd=n-240+10;end
   done=n==255;
   @(negedge clk);pv=0;fv=0;done=0;
   repeat(spacing)@(negedge clk);
  end
 end endtask
 task check;input integer offset,seq,base,f,drop;reg [15:0] crc,expected;begin
  if(got[offset]!==8'ha5 || got[offset+2]!==8'h55 || got[offset+3]!==seq)$fatal(1,"header");
  if(got[offset+5]!==f || got[offset+71]!==drop)$fatal(1,"snapshot/fault");
  if({got[offset+73],got[offset+72]}!==16'd256)$fatal(1,"sample count");
  for(k=0;k<16;k=k+1)if(got[offset+12+k]!==k+10)$fatal(1,"last feature");
  for(k=0;k<256;k=k+1)begin
   expected=base+k*97;
   if({got[offset+75+k*2],got[offset+74+k*2]}!==expected)$fatal(1,"PCM bank/order at %0d",k);
  end
  crc=16'hffff;
  for(k=0;k<594;k=k+1)begin
   crc=crc^{got[offset+k],8'd0};
   for(j=0;j<8;j=j+1)crc=crc[15]?(crc<<1)^16'h1021:crc<<1;
  end
  if({got[offset+595],got[offset+594]}!==crc)$fatal(1,"CRC");
 end endtask
 initial begin
  repeat(4)@(negedge clk);rst=0;
  frame(-15000,640);repeat(5)@(negedge clk);flags=8'h99;trace=0;
  // Another frame arrives during transmission; the first RAM bank is immutable.
  frame(-12000,640);wait(count==1192);repeat(30)@(negedge clk);
  check(0,1,-15000,8'h4d,0);check(596,2,-12000,8'h99,0);
  if({got[593],got[592],got[591],got[590],got[589],got[588],got[587],got[586]}!==64'h0103000200031234)
   $fatal(1,"command trace snapshot");
  out=$fopen("verification/pcm_report_fixture.bin","wb");
  for(c=0;c<count;c=c+1)$fwrite(out,"%c",got[c]);$fclose(out);
  // A partial PCM block is rejected explicitly, never silently padded as audio.
  @(negedge clk);done=1;@(negedge clk);done=0;
  wait(count==1788);repeat(30)@(negedge clk);
  if(!got[2*596+71][1])$fatal(1,"partial frame not flagged");
  $display("PASS PCM UART: signed exact samples, bank isolation, simultaneous last sample, last feature, immutable trace, CRC and partial-frame flag");$finish;
 end
 initial begin #50000000;$fatal(1,"PCM report timeout %0d",count);end
endmodule

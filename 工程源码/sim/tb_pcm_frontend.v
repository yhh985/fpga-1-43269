`timescale 1ns/1ps
// Actual decimation, spectral frontend and report boundaries at board cadence.
module tb_pcm_frontend;
 reg clk=0,rst=1,sv=0;reg signed [15:0] sample=0;always #10 clk=~clk;
 wire fv,done,pv,fault;wire [3:0] fi;wire signed [7:0] fd;wire signed [15:0] pcm;
 aca_kws_frontend #(.ADAPTIVE_VAD(1)) front(.clk(clk),.rst(rst),.sample_valid(sv),.sample(sample),
 .feature_valid(fv),.feature_index(fi),.feature_data(fd),.frame_done(done),.fault(fault),
 .debug_pcm_valid(pv),.debug_pcm(pcm));
 aca_pcm_feature_report report(.clk(clk),.rst_n(!rst),.pcm_valid(pv),.pcm(pcm),
 .feature_valid(fv),.feature_index(fi),.feature_data(fd),.frame_done(done),.flags(8'h4d),
 .reject_flags(8'd0),.debug_sequence(16'd0),.peak(16'd0),.noise(16'd0),.sample_count(16'd0),
 .debug_voiced(7'd0),.debug_duration(7'd0),.debug_logits(288'd0),
 .engine_state(8'd0),.command_trace(64'd0));
 integer n,j,forwarded=0,packets=0,bytes=0,out;
 reg signed [15:0] expected;reg completion_seen=0;
 always @(negedge clk)if(!rst)begin
  if(pv)begin
   expected=(forwarded%31-15)*60;
   if(pcm!==expected)$fatal(1,"decimated PCM differs %0d",forwarded);
   forwarded=forwarded+1;
  end
  if(report.send)begin $fwrite(out,"%c",report.byte_value);bytes=bytes+1;end
  if(report.index!=595)completion_seen=0;
  if(report.state==0 && report.index==595 && !completion_seen)begin
   if(report.pcm_mismatch || report.overrun || fault)$fatal(1,"real frontend report fault");
   if(bytes!=(packets+1)*596)$fatal(1,"packet boundary");
   packets=packets+1;
   completion_seen=1;
  end
 end
 initial begin
  out=$fopen("verification/pcm_frontend_fixture.bin","wb");
  repeat(4)@(negedge clk);rst=0;
  for(n=0;n<768;n=n+1)for(j=0;j<6;j=j+1)begin
   @(negedge clk);sv=1;sample=(n%31-15)*80;
   @(negedge clk);sv=0;repeat(1039)@(negedge clk);
  end
  wait(packets==3);$fclose(out);
  if(forwarded!=768)$fatal(1,"missing samples");
  $display("PASS real frontend PCM: exact 6-to-1 decimation, 256 samples/frame, actual spectral boundaries, three continuous packets, no overflow or mismatch");$finish;
 end
 initial begin #150000000;$fatal(1,"frontend PCM timeout %0d",packets);end
endmodule

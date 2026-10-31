`timescale 1ns/1ps
module tb_voice_robust;
 parameter FRAMES=200,RESULTS=1;
 reg clk=0,rst=1,fv=0,done=0;reg [3:0] fi=0;reg signed [7:0] fd=0;
 always #10 clk=~clk;
 reg [7:0] data[0:FRAMES*16-1];reg [31:0] mapping[0:FRAMES-1];
 reg [31:0] expected[0:RESULTS*9-1];reg [7:0] accepted[0:RESULTS-1];
 wire rv,ev,fault;wire [1:0] rc,ec;wire signed [31:0] a,b,c;
 aca_kws_engine #(.COOLDOWN_CYCLES(0)) dut(.clk(clk),.rst(rst),.feature_valid(fv),
  .feature_index(fi),.feature_data(fd),.frame_done(done),.result_valid(rv),.result_class(rc),
  .event_valid(ev),.event_command(ec),.logit0(a),.logit1(b),.logit2(c),.fault(fault));
 integer f,k,n=0,passes=0,idx;
 time inference_start,latency,max_latency=0;
 always @(negedge clk)begin
  if(dut.state==4)begin
   idx=n*9+dut.pass_index*3;
   if(n>=RESULTS || a!==expected[idx] || b!==expected[idx+1] || c!==expected[idx+2])
    $fatal(1,"pass mismatch result%0d pass%0d got %0d %0d %0d expected %0d %0d %0d",n,dut.pass_index,a,b,c,expected[idx],expected[idx+1],expected[idx+2]);
   passes=passes+1;
  end
  if(rv)begin
   latency=$time-inference_start;
   if(latency>20000000)$fatal(1,"inference exceeded 20ms: %0t",latency);
   if(latency>max_latency)max_latency=latency;
   if(rc!==accepted[n][1:0] || ev!==(accepted[n]!=0))$fatal(1,"decision mismatch %0d",n);
   if(ev && ec!==rc)$fatal(1,"direction mismatch");
   n=n+1;
  end
 end
 initial begin
  $readmemh("verification/robust_inputs.mem",data);$readmemh("verification/robust_map.mem",mapping);
  $readmemh("verification/robust_logits.mem",expected);$readmemh("verification/robust_class.mem",accepted);
  repeat(4)@(negedge clk);rst=0;
  for(f=0;f<FRAMES;f=f+1)begin
   for(k=0;k<16;k=k+1)begin @(negedge clk);fv=1;fi=k;fd=data[f*16+k];end
   @(negedge clk);fv=0;done=1;
   if(mapping[f]!=32'hffffffff)inference_start=$time;
   @(negedge clk);done=0;
   if(mapping[f]!=32'hffffffff)begin wait(rv);repeat(3)@(negedge clk);end
  end
  repeat(400000)@(negedge clk);
  if(fault || n!=RESULTS || passes!=RESULTS*3)$fatal(1,"count/fault %0d/%0d/%0d",n,passes,fault);
  $display("PASS inference latency at 50MHz: max %0t, endpoint quiet 192ms is additional",max_latency);
  $display("PASS robust voice: %0d endpoints, %0d exact pass logits, decisions/directions, long utterance and ring wrap",n,passes);$finish;
 end
 initial begin #500000000;$fatal(1,"watchdog f=%0d n=%0d",f,n);end
endmodule

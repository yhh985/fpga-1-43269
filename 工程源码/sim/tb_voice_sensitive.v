`timescale 1ns/1ps
module tb_voice_sensitive;
 parameter FRAMES=200,RESULTS=1;
 reg clk=0,rst=1,fv=0,done=0;reg [3:0] fi=0;reg signed [7:0] fd=0;
 always #10 clk=~clk;
 reg [7:0] data[0:FRAMES*16-1];reg [31:0] mapping[0:FRAMES-1];
 reg [31:0] expected[0:RESULTS*3-1];reg [7:0] accepted[0:RESULTS-1];
 wire rv,ev,fault;wire [1:0] rc,ec;wire signed [31:0] a,b,c;
 aca_kws_engine #(.COOLDOWN_CYCLES(0),.NORMALIZE_UTTERANCE(0),
 .CONSENSUS_PASSES(1),.PREQUIET_FRAMES(0),.MAX_UTTERANCE_FRAMES(64),
 .SHIFT(9),.MIN_MARGIN(109),.MIN_WINNER_SCORE(0),.RELAXED_MARGIN(0),
 .WEIGHTS_FILE("E:/anlo_project/liantiao/development/audio_crc/voice/model/weights.mem"),
 .BIAS_FILE("E:/anlo_project/liantiao/development/audio_crc/voice/model/bias.mem")) dut(
 .clk(clk),.rst(rst),.feature_valid(fv),.feature_index(fi),.feature_data(fd),
 .frame_done(done),.result_valid(rv),.result_class(rc),.event_valid(ev),
 .event_command(ec),.logit0(a),.logit1(b),.logit2(c),.fault(fault));
 integer f,k,n=0;time started,latency,max_latency=0;
 always @(negedge clk)if(rv)begin
  if(n>=RESULTS || a!==expected[n*3] || b!==expected[n*3+1] || c!==expected[n*3+2])
   $fatal(1,"native logits mismatch %0d: %0d %0d %0d",n,a,b,c);
  if(rc!==accepted[n][1:0] || ev!==(accepted[n]!=0))$fatal(1,"native decision mismatch %0d",n);
  if(ev && ec!==rc)$fatal(1,"native direction");
  latency=$time-started;if(latency>max_latency)max_latency=latency;
  if(latency>2000000)$fatal(1,"native inference over 2ms");
  n=n+1;
 end
 initial begin
  $readmemh("verification/sensitive_inputs.mem",data);$readmemh("verification/sensitive_map.mem",mapping);
  $readmemh("verification/sensitive_logits.mem",expected);$readmemh("verification/sensitive_class.mem",accepted);
  repeat(4)@(negedge clk);rst=0;
  for(f=0;f<FRAMES;f=f+1)begin
   for(k=0;k<16;k=k+1)begin @(negedge clk);fv=1;fi=k;fd=data[f*16+k];end
   @(negedge clk);fv=0;done=1;if(mapping[f]!=32'hffffffff)started=$time;
   @(negedge clk);done=0;
   if(mapping[f]!=32'hffffffff)begin wait(rv);repeat(3)@(negedge clk);end
  end
  repeat(120000)@(negedge clk);
  if(fault || n!=RESULTS)$fatal(1,"native count/fault %0d %0d",n,fault);
  $display("PASS sensitive native recognizer: %0d exact logits/decisions, isolated history, wrap and max latency %0t",n,max_latency);$finish;
 end
 initial begin #500000000;$fatal(1,"native watchdog %0d %0d",f,n);end
endmodule

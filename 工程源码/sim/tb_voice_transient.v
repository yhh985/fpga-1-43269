`timescale 1ns/1ps
module tb_voice_transient;
parameter FRAMES=200,RESULTS=1,CREDIT=1;
reg clk=0,rst=1,fv=0,done=0;
reg [3:0] fi=0;
reg signed [7:0] fd=0;
always #10 clk=~clk;
reg [7:0] data[0:FRAMES*16-1];
reg [31:0] expected_map[0:FRAMES-1];
reg [31:0] expected_logits[0:RESULTS*3-1];
reg [7:0] expected_class[0:RESULTS-1];
wire rv,ev,fault;wire [1:0] rc,ec;
wire signed [31:0] a,b,c;
aca_kws_engine #(.COOLDOWN_CYCLES(0),.TRANSIENT_CREDIT(CREDIT)) dut(
 .clk(clk),.rst(rst),.feature_valid(fv),.feature_index(fi),.feature_data(fd),
 .frame_done(done),.result_valid(rv),.result_class(rc),.event_valid(ev),
 .event_command(ec),.logit0(a),.logit1(b),.logit2(c),.fault(fault));
integer f,k,n=0;
always @(negedge clk) if(rv)begin
 if(n>=RESULTS)$fatal(1,"unexpected result");
 if(a!==expected_logits[n*3] || b!==expected_logits[n*3+1] || c!==expected_logits[n*3+2])
  $fatal(1,"logit mismatch result %0d: %0d %0d %0d",n,a,b,c);
 if(rc!==expected_class[n][1:0] || ev!==(expected_class[n]!=0))$fatal(1,"accept mismatch %0d",n);
 if(ev && ec!==rc)$fatal(1,"command mismatch");
 n=n+1;
end
initial begin
 $readmemh("verification/transient_inputs.mem",data);
 $readmemh("verification/transient_map.mem",expected_map);
 $readmemh("verification/transient_logits.mem",expected_logits);
 $readmemh("verification/transient_class.mem",expected_class);
 repeat(4)@(negedge clk);rst=0;
 for(f=0;f<FRAMES;f=f+1)begin
  for(k=0;k<16;k=k+1)begin @(negedge clk);fv=1;fi=k;fd=data[f*16+k];end
  @(negedge clk);fv=0;done=1;@(negedge clk);done=0;
  if(CREDIT && expected_map[f]!=32'hffffffff)begin wait(rv);repeat(3)@(negedge clk);end
 end
 repeat(400000)@(negedge clk);
 if(fault || n!=RESULTS)$fatal(1,"results/fault %0d/%0d",n,fault);
 $display("PASS voice transient: %0d endpoints, exact logits and accepted commands",n);$finish;
end
initial begin #200000000;$fatal(1,"timeout frame=%0d results=%0d",f,n);end
endmodule

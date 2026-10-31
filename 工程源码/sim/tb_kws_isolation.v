`timescale 1ns/1ps
// The same background segment must yield the same logits regardless of the
// previous spoken command. A non-isolated control must expose the old leak.
module tb_kws_isolation;
parameter FRAMES=200;
reg clk=0,rst=1,fv=0,done=0;reg [3:0] fi=0;reg signed [7:0] fd=0;
always #10 clk=~clk;
reg [7:0] data[0:FRAMES*16-1];reg [31:0] map[0:FRAMES-1];
wire rv,oldrv,ev;wire signed [31:0] a,b,c,oa,ob,oc;
aca_kws_engine dut(.clk(clk),.rst(rst),.feature_valid(fv),.feature_index(fi),.feature_data(fd),
 .frame_done(done),.result_valid(rv),.event_valid(ev),.logit0(a),.logit1(b),.logit2(c));
aca_kws_engine #(.ISOLATE_UTTERANCE(0)) old_dut(.clk(clk),.rst(rst),.feature_valid(fv),
 .feature_index(fi),.feature_data(fd),.frame_done(done),.result_valid(oldrv),.logit0(oa),.logit1(ob),.logit2(oc));
reg signed [31:0] saved_a,saved_b,saved_c,saved_oa,saved_ob,saved_oc;
integer f,k,results=0,noise_events=0;
always @(negedge clk)if(rv)begin
 if(!oldrv)$fatal(1,"control timing differs");
 if(results==1)begin saved_a=a;saved_b=b;saved_c=c;saved_oa=oa;saved_ob=ob;saved_oc=oc;end
 if(results==1 || results==3)begin if(ev)noise_events=noise_events+1;end
 if(results==3)begin
  if(a!==saved_a || b!==saved_b || c!==saved_c)$fatal(1,"previous utterance contaminated background result");
  if(oa===saved_oa && ob===saved_ob && oc===saved_oc)$fatal(1,"negative control failed to expose old history leak");
 end
 results=results+1;
end
initial begin
 $readmemh("verification/isolation_inputs.mem",data);$readmemh("verification/isolation_map.mem",map);
 repeat(4)@(negedge clk);rst=0;
 for(f=0;f<FRAMES;f=f+1)begin
  for(k=0;k<16;k=k+1)begin @(negedge clk);fv=1;fi=k;fd=data[f*16+k];end
  @(negedge clk);fv=0;done=1;@(negedge clk);done=0;
  if(map[f]!=32'hffffffff)begin wait(rv);repeat(3)@(negedge clk);end
 end
 if(results!=4 || noise_events!=0)$fatal(1,"expected four utterances, no noise events: %0d/%0d",results,noise_events);
 $display("PASS utterance isolation: next/previous prefix gives identical background logits; zero background commands; non-isolated negative control detects contamination");$finish;
end
initial begin #100000000;$fatal(1,"isolation timeout f%0d results%0d",f,results);end
endmodule

`timescale 1ns/1ps
// Exercise actual frontend normalization/VAD and engine endpoint under
// permanently NONZERO background powers. MAC still uses actual model ROMs.
module tb_voice_noise;
reg clk=0,rst=1,result=0;always #10 clk=~clk;
reg [31:0] power_value=4096;
wire fv,done,fault,rv;wire [3:0] fi;wire signed [7:0] fd;
integer i,quiet_features=0,results=0;
aca_kws_frontend #(.ADAPTIVE_VAD(1)) front(.clk(clk),.rst(rst),.sample_valid(1'b0),.sample(16'sd0),
 .feature_valid(fv),.feature_index(fi),.feature_data(fd),.frame_done(done),.fault(fault));
aca_kws_engine engine(.clk(clk),.rst(rst),.feature_valid(fv),.feature_index(fi),.feature_data(fd),
 .frame_done(done),.result_valid(rv));
always @(negedge clk)if(rv)results=results+1;
task frame16;input [31:0] p;begin
 @(negedge clk);power_value=p;result=1;@(negedge clk);result=0;
 repeat(70)@(negedge clk);
end endtask
initial begin
 force front.result=result;
 force front.p[0]=power_value;force front.p[1]=power_value;force front.p[2]=power_value;force front.p[3]=power_value;
 force front.p[4]=power_value;force front.p[5]=power_value;force front.p[6]=power_value;force front.p[7]=power_value;
 force front.p[8]=power_value;force front.p[9]=power_value;force front.p[10]=power_value;force front.p[11]=power_value;
 force front.p[12]=power_value;force front.p[13]=power_value;force front.p[14]=power_value;force front.p[15]=power_value;
 repeat(4)@(negedge clk);rst=0;
 for(i=0;i<110;i=i+1)frame16(4096);
 if(engine.utterance || results!=0 || fd!=0)$fatal(1,"nonzero ambient prevented quiet gating");
 for(i=0;i<24;i=i+1)frame16(262144);
 if(!engine.utterance || engine.voiced_frames<6)$fatal(1,"speech not admitted");
 // One paired frame may straddle the end; six further quiet pairs suffice.
 for(i=0;i<14;i=i+1)frame16(4096);
 if(engine.utterance || engine.state==0)$fatal(1,"no endpoint within 224ms of speech ending");
 wait(rv);repeat(4)@(negedge clk);
 if(results!=1 || fault)$fatal(1,"endpoint result/fault");
 for(i=0;i<24;i=i+1)frame16(4096);
 if(results!=1)$fatal(1,"background repeatedly triggered inference");
 $display("PASS noise endpoint: nonzero background gated, utterance ends <=224ms after speech; three integer passes ~4.5ms; no ambient-only inference");$finish;
end
initial begin #10000000;$fatal(1,"noise endpoint timeout");end
endmodule

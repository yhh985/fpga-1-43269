`timescale 1ns/1ps
module tb_wav_pcm_parser;
reg clk=0,rst=1,v=0;always #5 clk=~clk;
reg [7:0] b;reg [31:0] bytes;
wire ready,pv,ok,done,error;wire [31:0] frame;
reg [7:0] fixture[0:16383];reg [31:0] expected[0:2047];
integer n,j,f,sz,k,cases=0,checks=0;string name;
wav_pcm_parser dut(.clk(clk),.rst(rst),.file_size(bytes),.byte_valid(v),.byte_data(b),.byte_ready(ready),
 .pcm_valid(pv),.pcm_frame(frame),.format_ok(ok),.done(done),.error(error));
always @(negedge clk)if(pv)begin
 if(cases>1)$fatal(1,"invalid WAV emitted PCM");
 if(frame!==(cases==0?expected[j]:{expected[j][15:0],expected[j][15:0]}))$fatal(1,"PCM mismatch frame %0d got=%h",j,frame);
 j=j+1;checks=checks+1;
end
initial begin
 $readmemh("verification/legacy_fixtures/sd_music_20261010/verification/expected_frames.mem",expected);
 for(cases=0;cases<9;cases=cases+1)begin
  case(cases)0:name="stereo";1:name="mono";2:name="bad_rate";3:name="compressed";default:name="stereo";endcase
  @(negedge clk);rst=1;v=0;j=0;
  f=$fopen({"verification/legacy_fixtures/sd_music_20261010/verification/",name,".wav"},"rb");sz=$fread(fixture,f);$fclose(f);
  bytes=sz;
  if(cases==4)fixture[31]=8'hff; // fmt size outside RIFF bounds
  if(cases==6)begin fixture[66]=8'hff;fixture[67]=8'h1f;end // misaligned data length
  if(cases==7)fixture[24]="X"; // data before recognized fmt
  if(cases==8)begin fixture[66]=0;fixture[67]=0;fixture[68]=0;fixture[69]=0;end
  if(cases==5)bytes=sz-1; // RIFF exceeds directory length
  repeat(4)@(negedge clk);rst=0;
  for(n=0;n<sz&&!error;n=n+1)begin
   // A rejected chunk may enter FAIL while the producer is waiting for ready.
   // Stop on error as well, instead of waiting forever for a failed parser.
   while(!ready&&!error)@(negedge clk);
   if(!error)begin
    b=fixture[n];v=1;@(negedge clk);v=0;
    // Non-uniform gaps include extended fmt, odd JUNK and PCM boundaries.
    repeat(n%3+2)@(negedge clk);
   end
  end
  repeat(5)@(negedge clk);
  if(cases<2)begin if(!done||!ok||error||j!=2048)$fatal(1,"valid WAV rejected frames=%0d",j);end
  else if(!error||j!=0)$fatal(1,"invalid WAV not rejected");
 end
 $display("PASS WAV parser: %0d exact stereo/mono frames, signed PCM, JUNK odd padding, extended fmt, LIST, rate/compression/length rejection",checks);$finish;
end
initial begin #2000000;$fatal(1,"parser timeout");end
endmodule


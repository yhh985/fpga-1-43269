`timescale 1ns/1ps
module tb_music_diagnostics;
 reg clk=0,rst=1,b=0,l=0,d=0,sv=0,ch=0,good=0;
 always #10 clk=~clk;
 wire [3:0] state;
 music_link_monitor #(.WINDOW_BITS(5)) mon(.clk(clk),.rst(rst),
  .bclk_sample(b),.lrck_sample(l),.data_sample(d),.sample_valid(sv),
  .channel(ch),.good(good),.state(state));
 reg [255:0] status=0;
 reg ok=0;reg [3:0] returned=0;
 mic_overlay overlay(.clk(clk),.rst(rst),.vs(1'b0),.de(1'b0),.enable(1'b1),
  .online(1'b1),.fx_requested(1'b1),.fx_return_ok(ok),.fx_return_state(returned),
  .music_mode(1'b1),.music_track(3'd0),.music_tracks(4'd2),.status(status),
  .rgb(24'd0),.out_rgb());
 task text_check;input [87:0] expected;begin
  #1;if(overlay.mode_text!==expected)$fatal(1,"label %s expected %s",overlay.mode_text,expected);
 end endtask
 integer i;
 initial begin
  #25;rst=0;
  repeat(70)@(negedge clk);
  if(state!==0)$fatal(1,"idle signals called active");
  for(i=0;i<100;i=i+1)begin
   @(negedge clk);b=~b;l=i%4==0?~l:l;d=~d;sv=1;ch=i%2;good=1;
  end
  #1;if(state!==4'hf)$fatal(1,"good stereo not detected: %h",state);
  good=0;
  for(i=0;i<100;i=i+1)begin @(negedge clk);b=~b;l=~l;d=~d;end
  #1;if(state!==4'he)$fatal(1,"DATA toggles mistaken for CRC success: %h",state);
  sv=0;
  repeat(100)@(negedge clk);
  #1;if(state!==0)$fatal(1,"link activity did not expire");
  text_check("FX OLD ACA ");
  status[13]=1;text_check("FX NO BCLK ");
  status[31]=1;text_check("FX NO LRCK ");
  status[30]=1;text_check("FX NO DATA ");
  status[22:21]=1;text_check("FX CLK LOW ");
  status[22:21]=2;text_check("FX SLOT 64 ");
  status[22:21]=3;text_check("FX SLOT ERR");
  status[22:21]=0;
  status[29]=1;text_check("FX IN CRC  ");
  status[28]=1;text_check("FX NO RET  ");
  returned=4'he;text_check("FX OUT CRC ");
  ok=1;status[20:19]=1;text_check("FX ECHO    ");
  status[20:19]=2;text_check("FX LOWPASS ");
  status[20:19]=3;text_check("FX TREMOLO ");
  status[26]=1;#1;
  if(overlay.command_text!=="SWAP")$fatal(1,"clock correction indicator missing");
  status[15]=1;status[25:24]=1;#1;
  if(overlay.command_text!=="NEXT")$fatal(1,"music clock flag overwrote voice command");
  status[25:24]=3;#1;
  if(overlay.command_text!=="SEND")$fatal(1,"pending command not shown");
  status[6]=1;#1;
  if(overlay.command_text!=="FAIL")$fatal(1,"failed link not shown");
  status[6]=0;status[25:24]=1;
  status[14]=1;status[9:8]=3;
  status[12:10]=1;text_check("VOICE CAL  ");
  status[12:10]=2;text_check("VOICE HEAR ");
  status[12:10]=3;text_check("VOICE THINK");
  status[12:10]=4;text_check("VOICE AGAIN");
  status[12:10]=5;text_check("MIC NO PCM ");
  status[12:10]=6;text_check("VOICE ERROR");
  status[12:10]=7;text_check("VOICE QUIET");
  status[12:10]=0;text_check("VOICE READY");
  status[14]=0;text_check("VOICE WAIT ");
  $display("PASS music diagnostics: idle, clock/data activity, good stereo, invalid CRC, expiry, thirteen screen labels, SWAP and voice isolation");
  $finish;
 end
endmodule

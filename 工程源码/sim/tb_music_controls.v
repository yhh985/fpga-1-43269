`timescale 1ns/1ps
module tb_music_controls;
reg clk=0,rst=1,sw4=1,sw1=1,frame=0,svalid=0;
reg signed [15:0] sample=0;
wire [23:0] sample24={sample,8'd0};
reg [1:0] mode=0;
reg [255:0] status=0;
reg online=1,playing=1,paused=0,transition=0;
integer events=0,k;real phase;reg before_toggle;
always #10 clk=~clk;
top #(.SWITCH_DEBOUNCE_CYCLES(8)) dut(.clk(clk),.key1(1'b1),.key2(1'b1),.key3(1'b1),.key4(1'b1),
 .sw1(sw1),.sw2(1'b1),.sw3(1'b1),.sw4(sw4),.sd_miso(1'b1),.link_rx(1'b1),.music_return(1'b0));
defparam dut.u_music_visual_link.COOLDOWN_FRAMES=3;
task cycles;input integer n;begin repeat(n)@(negedge clk);end endtask
task boundary;begin frame=1;cycles(1);frame=0;cycles(1);end endtask
task tone;input integer freq,windows;begin
 for(k=0;k<1024*windows;k=k+1)begin
  phase=6.283185307179586*freq*k/48000.0;
  sample=$rtoi(10000*$sin(phase));svalid=1;cycles(1);svalid=0;cycles(99);
 end
 cycles(100);
end endtask
always @(posedge clk)if(!rst && dut.audio_link_start)events=events+1;
initial begin
 force dut.rst_all=rst;force dut.rst_sd=rst;force dut.video_clk=clk;
 force dut.sd_card_clk=clk;force dut.ext_mem_clk=clk;force dut.ext_mem_clk_sft=clk;force dut.audio_mclk=1'b0;
 force dut.remote_online=online;force dut.remote_status=status;force dut.playback_mode=mode;
 force dut.music_playing=playing;force dut.playback_paused=paused;force dut.trans_active=transition;
 force dut.transition_frame_start=frame;force dut.audio_valid=svalid;force dut.local_left=sample24;
 cycles(5);rst=0;cycles(15);
 sw4=0;cycles(2);sw4=1;cycles(3);boundary;
 if(dut.osd_frame_enable)$fatal(1,"OSD bounce leaked");
 sw4=0;cycles(20);
 if(dut.osd_frame_enable)$fatal(1,"OSD changed mid-frame");
 boundary;if(!dut.osd_frame_enable)$fatal(1,"OSD stable ON missing");
 sw4=1;cycles(2);sw4=0;cycles(4);boundary;
 if(!dut.osd_frame_enable)$fatal(1,"OSD off bounce leaked");
 sw4=1;cycles(20);if(!dut.osd_frame_enable)$fatal(1,"OSD off changed mid-frame");
 boundary;if(dut.osd_frame_enable)$fatal(1,"OSD stable OFF missing");
 status[13]=1;status[0]=1;cycles(8);
 if(!dut.music_enable || dut.audio_play_en || dut.auto_play_en)$fatal(1,"manual background gate");
 mode=1;cycles(8);if(!dut.music_enable || !dut.auto_play_en)$fatal(1,"auto background gate");
 status[15]=1;cycles(8);if(dut.music_enable)$fatal(1,"voice must mute background");
 status[15]=0;online=0;cycles(8);if(dut.music_enable)$fatal(1,"offline background state replay");
 online=1;status[0]=0;mode=2;sw1=0;cycles(20);boundary;cycles(8);
 if(!dut.music_tone_enable)$fatal(1,"music tone gate missing");
 before_toggle=dut.audio_next_toggle;tone(400,3);
 if(events || dut.audio_next_toggle!=before_toggle)$fatal(1,"first tone must only establish baseline");
 transition=1;tone(800,5);
 if(events!=1 || !dut.audio_change_pending || dut.audio_next_toggle!=before_toggle)$fatal(1,"transition lost pending music request events=%0d pending=%b peak=%d power=%d overflow=%b count=%d",events,dut.audio_change_pending,dut.tone_peak_index,dut.tone_peak_power,dut.tone_overflow,dut.u_music_visual_link.stable_count);
 transition=0;cycles(8);
 if(dut.audio_next_toggle==before_toggle || dut.audio_change_pending)$fatal(1,"pending music change not consumed");
 tone(800,5);if(events!=1)$fatal(1,"same frequency repeated change");
 boundary;boundary;boundary;tone(1600,5);if(events!=2)$fatal(1,"second changed frequency missing");
 mode=0;cycles(10);tone(400,3);if(events!=2)$fatal(1,"manual background requested music cut");
 mode=2;sw1=1;cycles(20);boundary;cycles(8);tone(800,5);if(events!=2)$fatal(1,"SW1 off still cuts");
 $display("PASS music controls: OSD bounce and frame commits, background manual/auto/voice/offline, real PCM frequency changes, cooldown, pending transition and SW1 gates");$finish;
end
initial begin #200000000;$fatal(1,"music controls timeout");end
endmodule

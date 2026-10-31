`timescale 1ns/1ps
// Real ACA and HX tops and UART; storage/PLLs/encrypted HDMI are stubs.
// Observe the actual HDMI PCM input, not a standalone replacement receiver.
module tb_dual_board_music;
 reg clk=0,aclk=0,pclk=0,mclk=0,rst=1;
 always #10 clk=~clk;
 initial begin #3;forever #10 aclk=~aclk;end
 always #20 pclk=~pclk;
 always #40.667 mclk=~mclk;
 reg bgkey=1;
 reg s2=1,s3=1,s4=1,broken=0,swap_clocks=0,drop_ack=0;
 wire htx,atx,bclk,lrck,source,returned;
 wire abclk,alrck,adata,hreturn;
 assign #7 abclk=swap_clocks?lrck:bclk;
 assign #42 alrck=swap_clocks?bclk:lrck; // Independent pin skew.
 assign #22 adata=source;
 assign #17 hreturn=returned^broken;
 tri1 sda;
 reg fifo_valid=0;
 always @(posedge mclk)fifo_valid<=hx.music_pop;
 top hx(.clk(clk),.link_rx(atx),.link_tx(htx),.music_bclk(bclk),
  .music_lrck(lrck),.music_out(source),.music_return(hreturn),
  .key1(1'b1),.key2(1'b1),.key3(1'b1),.key4(1'b1),
  .sw1(1'b1),.sw2(1'b1),.sw3(1'b1),.sw4(1'b1),.sd_miso(1'b1));
 aca420_audio_top #(.KEY_DEBOUNCE_CYCLES(3),.COMMAND_DISPLAY_CYCLES(150000),.COMMAND_MIN_VISIBLE_CYCLES(1000)) aca(.clk(aclk),.reset_n(!rst),
  .music_bclk(abclk),.music_lrck(alrck),.music_in(adata),.music_out(returned),
  .key_monitor_n(bgkey),.key_slot_n(s2),.key_learn_n(s3),.key_demo_n(s4),
  .iic_0_sda(sda),.I2S_DI(1'b0),.link_rx(drop_ack?1'b1:htx),.link_tx(atx));
 defparam aca.u_keys.LONG=50;
 defparam aca.u_link.PRESCALE=2;
 defparam aca.u_link.PERIOD=10000;
 defparam aca.u_link.RETRY=30000;
 defparam hx.u_remote.PRESCALE=2;
 integer checks=0,a,c,i;
 reg toggle_before;
 task frames;input integer n;begin repeat(n)@(posedge hx.audio_valid);end endtask
 task check_pcm;input integer el,er,tolerance;begin
  frames(50);
  for(i=0;i<30;i=i+1)begin
   @(posedge pclk);while(!hx.audio_valid)@(posedge pclk);
   a=$signed(hx.u_hdmi_1_4b_transmitter_core_wrapper.I_audio_left_data)>>>8;
   c=$signed(hx.u_hdmi_1_4b_transmitter_core_wrapper.I_audio_right_data)>>>8;
   if(a<el-tolerance || a>el+tolerance || c<er-tolerance || c>er+tolerance)
    $fatal(1,"HDMI PCM mode%0d got%0d/%0d expected%0d/%0d",aca.music_effect,a,c,el,er);
   checks=checks+1;
  end
 end endtask
 task effect;input integer n;begin
  @(negedge aclk);s3=0;repeat(80)@(negedge aclk);s3=1;
  wait(hx.remote_status[20:19]==n);
  if(aca.music_effect!==n)$fatal(1,"S3 mode/status mismatch");
 end endtask
 initial begin
  force hx.rst_all=rst;force hx.rst_sd=rst;
  force hx.video_clk=pclk;force hx.audio_mclk=mclk;
  force hx.sd_card_clk=clk;force hx.ext_mem_clk=clk;force hx.ext_mem_clk_sft=clk;
  force hx.playback_mode=2'd2;force hx.music_ok=1'b1;
  force hx.music_used=13'd4096;force hx.music_empty=1'b0;
  force hx.music_valid=fifo_valid;force hx.music_data={16'(-15000),16'(12000)};
  force aca.rst_sys=rst;force aca.rst_audio=rst;
  #400;rst=0;wait(hx.remote_online && aca.link_online);
  force hx.playback_mode=2'd0;
  repeat(10)@(negedge clk);
  if(hx.music_enable)$fatal(1,"background must default off");
  bgkey=0;@(negedge aclk);bgkey=1;repeat(12)@(negedge aclk);
  if(aca.background_music)$fatal(1,"background button bounce accepted");
  bgkey=0;repeat(20)@(negedge aclk);bgkey=1;
  wait(hx.background_music_en);repeat(10)@(negedge clk);
  if(!hx.music_enable || hx.audio_play_en || hx.auto_play_en)$fatal(1,"manual background changed image mode");
  check_pcm(3000,-3750,0);
  force hx.playback_mode=2'd1;repeat(10)@(negedge clk);
  if(!hx.music_enable || !hx.auto_play_en || hx.audio_play_en)$fatal(1,"automatic background changed timer mode");
  check_pcm(3000,-3750,0);
  bgkey=0;repeat(20)@(negedge aclk);bgkey=1;
  wait(!hx.background_music_en);repeat(10)@(negedge clk);
  if(hx.music_enable)$fatal(1,"background off failed");
  force hx.playback_mode=2'd2;repeat(10)@(negedge clk);
  check_pcm(3000,-3750,0);
  toggle_before=hx.music_next_toggle;
  s2=0;repeat(20)@(negedge aclk);s2=1;wait(hx.music_next_toggle!=toggle_before);
  toggle_before=hx.music_prev_toggle;
  s3=0;repeat(20)@(negedge aclk);s3=1;wait(hx.music_prev_toggle!=toggle_before);
  effect(1);check_pcm(1500,-1875,0);
  if(!hx.music_return_present)$fatal(1,"CRC return never became valid");
  broken=1;frames(12);check_pcm(0,0,0);
  if(hx.music_return_present || hx.return_errors==0)$fatal(1,"return corruption not diagnosed");
  broken=0;check_pcm(1500,-1875,0);
  effect(2);check_pcm(3000,-3750,2);
  // Change the physical INPUT ordering while playing. Require actual CRC
  // round-trip audio and UART-reported correction, not just ratio detection.
  swap_clocks=1;
  wait(aca.music_clocks_swapped && hx.remote_status[26]);
  wait(hx.music_return_present);
  check_pcm(3000,-3750,2);
  effect(3);check_pcm(3000,-3750,0);
  swap_clocks=0;
  wait(!aca.music_clocks_swapped && !hx.remote_status[26]);
  wait(hx.music_return_present);
  check_pcm(3000,-3750,0);
  effect(0);check_pcm(3000,-3750,0);
  frames(600); // Allow recent activity and its UART snapshot to publish.
  if(hx.remote_status[13]!==1'b1 || hx.remote_status[31:28]!==4'hf)
   $fatal(1,"ACA link diagnostics missing from actual UART status: %h",hx.remote_status[31:0]);
  if(hx.remote_status[22:21]!==0)$fatal(1,"normal 32-bit slot misdiagnosed");
  if(hx.music_return_state!==4'hf)$fatal(1,"return diagnostics incomplete");
  force aca.music_clock_code=2'd3;
  wait(hx.remote_status[22:21]==3);
  release aca.music_clock_code;
  wait(hx.remote_status[22:21]==0);
  if(hx.remote_crc_errors || aca.link_crc_errors)$fatal(1,"UART CRC errors");
  // Actual S4 -> status packet -> HX voice permission -> ACA READY handshake.
  s4=0;repeat(20)@(negedge aclk);s4=1;
  wait(aca.voice_running && hx.voice_active);
  wait(hx.remote_status[9:8]==3);
  // Isolate stage publication from the codec/feature DSP (tested separately).
  force aca.cfg_error=0;force aca.cfg_done=1;force aca.sample_alive=1;
  force aca.vad_ready=1;force aca.kws_window_ready=1;force aca.kws_quiet_ready=1;
  wait(hx.remote_status[12:10]==0);
  // A lost ACK must not turn a local recognition into a phantom NEXT.
  // The host executes once, retries are deduplicated, and NEXT expires.
  force aca.kws_utterance=0;force aca.kws_rejected=0;
  toggle_before=hx.voice_next_toggle;drop_ack=1;
  force aca.kws_command=1;@(negedge aclk);force aca.kws_event=1;
  @(negedge aclk);release aca.kws_event;
  wait(hx.voice_next_toggle!=toggle_before);repeat(10)@(negedge aclk);
  if(aca.last_command!=3 || !aca.command_pending)$fatal(1,"unacknowledged command must show SEND");
  toggle_before=hx.voice_next_toggle;drop_ack=0;
  wait(aca.last_command==1);
  force aca.kws_utterance=1;repeat(4)@(negedge aclk);
  if(aca.last_command!=1)$fatal(1,"short noise erased ACK before minimum visible interval");
  force aca.kws_utterance=0;repeat(1000)@(negedge aclk);
  if(hx.voice_next_toggle!=toggle_before)$fatal(1,"retried voice NEXT executed twice");
  force aca.kws_utterance=1;repeat(4)@(negedge aclk);
  if(aca.last_command!=0)$fatal(1,"new utterance retained stale NEXT");
  force aca.kws_utterance=0;
  force aca.kws_command=2;@(negedge aclk);force aca.kws_event=1;
  @(negedge aclk);release aca.kws_event;
  wait(aca.last_command==2);wait(aca.last_command==0);
  release aca.kws_command;release aca.kws_utterance;release aca.kws_rejected;
  $display("PASS voice delivery feedback: lost ACK, duplicate suppression, host receipt before NEXT, clear on new utterance and expiry");
  force aca.vad_speech=1;wait(hx.remote_status[12:10]==2);release aca.vad_speech;
  force aca.kws_processing=1;wait(hx.remote_status[12:10]==3);release aca.kws_processing;
  force aca.kws_rejected=1;repeat(4)@(negedge aclk);release aca.kws_rejected;
  wait(hx.remote_status[12:10]==4);
  force aca.sample_alive=0;wait(hx.remote_status[12:10]==5);
  force aca.cfg_error=1;wait(hx.remote_status[12:10]==6);
  release aca.cfg_error;release aca.cfg_done;release aca.sample_alive;
  release aca.vad_ready;release aca.kws_window_ready;release aca.kws_quiet_ready;
  s4=0;repeat(20)@(negedge aclk);s4=1;
  wait(!hx.voice_active && !aca.voice_mode);
  wait(hx.remote_status[9:8]!=3);
  $display("PASS voice status handshake: actual S4/permission, READY/HEAR/THINK/AGAIN/NO PCM/ERROR, exit marker reset");
  $display("PASS dual board music: %0d HDMI PCM frames, actual S2/S3 next/prev, UART effect cycle, stereo, bypass/effects, corrupt wire mute/recovery, live clock interchange and restoration",checks);
  $finish;
 end
 initial begin #100000000;$fatal(1,"dual board timeout");end
endmodule

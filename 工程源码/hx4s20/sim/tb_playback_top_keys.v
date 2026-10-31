`timescale 1ns/1ps
// Actual application top and physical active-low key waveforms. Peripheral
// stubs are the same as the separately verified top video integration test.
module tb_playback_top_keys;
parameter BMP_TEST=0;
reg clk=0,rst=1,key1=1,key2=1,key3=1,key4=1,sw1=1,tone_event=0;
always #10 clk=~clk;
integer k1_short=0,k2_short=0,k2_long=0,k4_short=0,k4_long=0;
reg previous_audio;
reg track_next_before,track_prev_before;
reg [6:0] source_pic=0;
reg source_valid=1;
wire [5:0] seg_sel;
wire [7:0] seg_data;
integer image,transition,display_checks=0;
top #(.SD_IMAGE_COUNT(128),.USER_BMP_TEST(BMP_TEST),.SWITCH_DEBOUNCE_CYCLES(3),.KEY_LONG_CYCLES(40)) dut(
 .link_rx(sensor_tx),.link_tx(host_tx),.clk(clk),.key1(key1),.key2(key2),.key3(key3),.key4(key4),
 .sw1(sw1),.sw2(1'b1),.sw3(1'b1),.sw4(1'b1),.sd_miso(1'b1),.seg_sel(seg_sel),.seg_data(seg_data));
wire sensor_tx,host_tx,sensor_online,failed,qoverflow;wire [15:0] crc;
reg fire=0;reg [7:0] remote_cmd=0;
reg [255:0] remote_test_status=256'h123456;
wire permit;
link_sensor #(.PRESCALE(2),.PERIOD(24000),.RETRY(30000),.LINK_TIMEOUT(300000)) sensor(
 .clk(clk),.rst(rst),.rx(host_tx),.tx(sensor_tx),.status(remote_test_status),.host_voice_enable(permit),
 .event_valid(fire),.event_command(remote_cmd),.online(sensor_online),
 .event_failed(failed),.queue_overflow(qoverflow),.crc_errors(crc));
defparam dut.u_remote.PRESCALE=2;
task command_remote;input [7:0] c;begin
 wait(sensor.ready_session && !sensor.waiting && !sensor.queued);
 @(negedge clk);remote_cmd=c;fire=1;@(negedge clk);fire=0;
 wait(sensor.waiting);wait(!sensor.waiting);cycles(12);
end endtask
// Speed up scanning only; exercise the real active-low board outputs.
defparam dut.seg_scan_m0.SCAN_COUNT=1;
function [6:0] digit;input integer n;begin
 case(n)
  0:digit=7'b1000000;1:digit=7'b1111001;2:digit=7'b0100100;
  3:digit=7'b0110000;4:digit=7'b0011001;5:digit=7'b0010010;
  6:digit=7'b0000010;7:digit=7'b1111000;8:digit=7'b0000000;
  9:digit=7'b0010000;
  default:digit=7'b1111111;
 endcase
end endfunction
task check_display;
 input integer playback,operation,effect,photo;
 input paused;
 integer n;
 reg [4:0] seen;
 reg [7:0] expected;
 begin
  cycles(8);seen=0;
  for(n=0;n<24;n=n+1)begin
   @(posedge clk);#2;
   case(seg_sel)
    6'b111110:begin expected={1'b1,digit(photo/10)};seen[4]=1;end
    6'b111101:begin expected={1'b1,digit(photo%10)};seen[3]=1;end
    6'b111011:begin expected={!paused,digit(playback)};seen[2]=1;end
    6'b110111:begin expected={1'b1,digit(operation)};seen[1]=1;end
    6'b101111:begin expected={1'b1,digit(effect)};seen[0]=1;end
    6'b011111:expected=8'hff;
    default:$fatal(1,"invalid digit select %b",seg_sel);
   endcase
   if(seg_data!==expected)$fatal(1,"wrong segments select%b got%h expected%h playback%0d operation%0d transition%0d photo%0d pause%0b",seg_sel,seg_data,expected,playback,operation,effect,photo,paused);
   display_checks=display_checks+1;
  end
  if(seen!=5'b11111)$fatal(1,"five digit scan incomplete");
  @(negedge clk);
 end
endtask
always @(posedge clk)if(!rst)begin
 if(dut.key1_short_pulse)k1_short=k1_short+1;
 if(dut.key2_short_pulse)k2_short=k2_short+1;
 if(dut.key2_long_pulse)k2_long=k2_long+1;
 if(dut.key4_short_pulse)k4_short=k4_short+1;
 if(dut.key4_long_pulse)k4_long=k4_long+1;
end
task cycles;input integer n;begin repeat(n)@(negedge clk);end endtask
task k2_click;begin key2=0;cycles(12);key2=1;cycles(12);end endtask
task k4_click;begin key4=0;cycles(12);key4=1;cycles(12);end endtask
task k4_hold;begin key4=0;cycles(90);key4=1;cycles(12);end endtask
task audio_request;input accepted;
 begin
  previous_audio=dut.audio_next_toggle;tone_event=1;cycles(1);tone_event=0;cycles(4);
  if((dut.audio_next_toggle!=previous_audio)!==accepted)$fatal(1,"audio request gate mode=%d paused=%d",dut.playback_mode,dut.playback_paused);
 end
endtask
initial begin
 force dut.rst_all=rst;force dut.rst_sd=rst;force dut.video_clk=clk;force dut.sd_card_clk=clk;
 force dut.ext_mem_clk=clk;force dut.ext_mem_clk_sft=clk;force dut.audio_mclk=1'b0;
 force dut.display_valid=source_valid;force dut.current_pic_idx=source_pic;force dut.display_valid_frame=1'b1;
 force dut.video_test_active=1'b0;force dut.test_mode=1'b0;force dut.test_mode_sync=2'b00;
 force dut.trans_active=1'b0;force dut.audio_link_start=tone_event;
 force dut.music_playing=1'b1;force dut.transition_frame_start=1'b1;
 cycles(5);rst=0;cycles(12);
 if(dut.playback_mode!=0 || dut.playback_paused || dut.op_mode!=0 || !dut.key1_next_wide)$fatal(1,"startup controls wrong");
 check_display(0,0,0,1,0);
 audio_request(0);
 key2=0;cycles(1);key2=1;cycles(10);
 if(k2_short || dut.playback_mode!=0)$fatal(1,"key bounce switched mode");
 key1=0;cycles(12);key1=1;cycles(12);
 if(k1_short!=1 || dut.key1_next_wide)$fatal(1,"physical K1 did not request next picture");
 k2_click;if(dut.playback_mode!=1 || !dut.auto_play_en || dut.audio_play_en)$fatal(1,"K2 manual-to-auto failed");
 check_display(1,0,0,1,0);
 audio_request(0);
 k2_click;if(dut.playback_mode!=2 || dut.auto_play_en || !dut.audio_play_en)$fatal(1,"K2 auto-to-audio failed");
 check_display(2,0,0,1,0);

 track_next_before=dut.music_next_toggle;track_prev_before=dut.music_prev_toggle;
 command_remote(4);if(dut.music_next_toggle==track_next_before||dut.playback_paused)$fatal(1,"music NEXT routed incorrectly");
 command_remote(5);if(dut.music_prev_toggle==track_prev_before||dut.playback_paused)$fatal(1,"music PREV routed incorrectly");
 sw1=0;cycles(16);
 audio_request(1);
 key2=0;cycles(90);key2=1;cycles(12);
 if(k2_long!=1 || k2_short!=2 || dut.playback_mode!=2 || dut.trans_mode_r!=1)$fatal(1,"K2 long press changed playback or repeated transition selection");
 check_display(2,0,1,1,0);
 k4_hold;
 if(!dut.playback_paused || dut.op_mode!=0 || k4_short || k4_long!=1)$fatal(1,"K4 hold failed to pause exclusively");
 check_display(2,0,1,1,1);
 audio_request(0);
 k4_hold;if(dut.playback_paused || dut.op_mode!=0 || k4_long!=2)$fatal(1,"K4 hold failed to resume once");
 k2_click;if(dut.playback_mode!=0)$fatal(1,"K2 audio-to-manual failed");
 check_display(0,0,1,1,0);
 k4_click;if(dut.op_mode!=1)$fatal(1,"K4 short did not select brightness");
 check_display(0,1,1,1,0);
 k2_click;if(dut.playback_mode!=0 || dut.brightness_r!=15)$fatal(1,"brightness decrement changed playback");
 k4_hold;if(!dut.playback_paused || dut.op_mode!=1)$fatal(1,"pause unavailable in brightness mode");
 check_display(0,1,1,1,1);
 k4_hold;if(dut.playback_paused || dut.op_mode!=1)$fatal(1,"resume altered brightness operation mode");
 k4_click;if(dut.op_mode!=2)$fatal(1,"contrast operation missing");
 check_display(0,2,1,1,0);
 k4_click;if(dut.op_mode!=3 || dut.zoom_level!=1)$fatal(1,"zoom page missing");
 check_display(0,3,1,1,0);
 key1=0;cycles(12);key1=1;cycles(12);if(dut.zoom_level!=2 || dut.playback_mode!=0 || !dut.key1_next_wide)$fatal(1,"zoom-in changed picture/playback");
 key1=0;cycles(12);key1=1;cycles(12);if(dut.zoom_level!=3)$fatal(1,"2x missing");
 key1=0;cycles(12);key1=1;cycles(12);if(dut.zoom_level!=3)$fatal(1,"zoom upper bound");
 k2_click;k2_click;k2_click;if(dut.zoom_level!=0||dut.playback_mode!=0)$fatal(1,"zoom-out changed playback");
 k2_click;if(dut.zoom_level!=0)$fatal(1,"zoom lower bound");
 key3=0;cycles(12);key3=1;cycles(12);if(dut.zoom_level!=1||dut.filter_mode_r!=0)$fatal(1,"zoom reset changed filter");
 check_display(0,3,1,1,0);
 k4_click;if(dut.op_mode!=0 || k4_short!=4 || k4_long!=4)$fatal(1,"four-page operation cycle wrong");
 for(transition=2;transition<=7;transition=transition+1)begin
  key2=0;cycles(90);key2=1;cycles(12);
  check_display(0,0,transition%7,1,0);
 end
 for(image=0;image<99;image=image+1)begin
  source_pic=image;check_display(0,0,0,image+1,0);
 end
 source_valid=0;check_display(0,0,0,0,0);
 // Send all commands through real UART packet and ACK endpoints into top.
 previous_audio=dut.audio_next_toggle;
 command_remote(1);
 if(dut.audio_next_toggle==previous_audio)$fatal(1,"UART NEXT did not reach scheduler toggle");
 command_remote(2);if(!dut.playback_paused)$fatal(1,"UART PAUSE failed");
 command_remote(2);if(dut.playback_paused)$fatal(1,"UART RESUME failed");
 command_remote(3);if(dut.trans_mode_r!=1)$fatal(1,"UART FX failed");
 if(failed || qoverflow || crc)$fatal(1,"UART endpoint errors");
 // Real UART status -> mute and host ACK permission -> directional commands.
 k2_click;k2_click;
 if(!dut.audio_play_en)$fatal(1,"music setup");
 remote_test_status[15]=1;
 wait(permit);cycles(12);
 if(dut.audio_play_en || dut.auto_play_en || !dut.voice_active)$fatal(1,"voice/music interlock");
 previous_audio=dut.voice_next_toggle;command_remote(1);
 if(dut.voice_next_toggle==previous_audio)$fatal(1,"voice NEXT missing");
 previous_audio=dut.voice_prev_toggle;command_remote(2);
 if(dut.voice_prev_toggle==previous_audio || dut.playback_paused)$fatal(1,"voice PREV confused with pause");
 remote_test_status[15]=0;wait(!permit);cycles(12);
 if(!dut.audio_play_en || dut.voice_active)$fatal(1,"music did not resume on exit");
 $display("PASS voice mode: real UART status/ACK permission, music mute, NEXT/PREV, no accidental pause, exit restores music");
 $display("ALL TESTS PASSED: BMP_TEST=%0d actual top UART NEXT/PAUSE/RESUME/FX, physical keys, MAN/AUTO/AUD cycle, all seven transitions, operations, pause DP, committed photos01-99 and unloaded00, %0d physical segment checks",BMP_TEST,display_checks);$finish;
end
initial begin #15000000;$fatal(1,"physical key test timeout");end
endmodule

`timescale 1ns/1ps
// Real MAIN_SD_FEATURES scheduler. Transport and frame completion are driven
// independently to exercise ownership, coalescing, pause and failed redraws.
module tb_zoom_scheduler;
reg clk=0,rst=1;always #5 clk=~clk;
reg initialized=0,ready=1,scanned=0,found=0,paused=0,failed=0;
reg mem_toggle=0,reader_toggle=0;reg [1:0] reader_index=0,zoom=1;
reg vn=0,vp=0;
reg [31:0] sector=100;
wire valid;wire [2:0] pic;wire [1:0] disp,shown;
integer launches=0;
sd_card_bmp #(.CLK_FREQ_HZ(1000),.MAIN_SD_FEATURES(1),.FIT_ASPECT(1)) dut(
 .clk(clk),.rst(rst),.key_next(1'b1),.auto_play_enable(1'b0),
 .voice_next_toggle(vn),.voice_prev_toggle(vp),.audio_play_enable(1'b0),
 .playback_pause(paused),.test_mode(1'b0),.audio_next_toggle(1'b0),
 .zoom_level(zoom),.display_zoom(shown),.audio_clk(clk),.music_pop(1'b0),
 .music_next_toggle(1'b0),.music_prev_toggle(1'b0),
 .bmp_width(16'd640),.bmp_height(16'd480),.display_valid(valid),
 .write_finish_toggle(mem_toggle),.read_buffer_toggle(reader_toggle),.read_buffer_index(reader_index),
 .disp_buf_idx(disp),.current_pic_idx(pic),.write_req_ack(1'b1),.write_data_ready(1'b1),.SD_MISO(1'b1));
always @(posedge clk)if(!rst && dut.load_start_pulse)begin
 launches=launches+1;
 if(valid && dut.write_buf_idx==disp)$fatal(1,"writer overwrote displayed buffer");
end
task cycles;input integer n;begin repeat(n)@(negedge clk);end endtask
task start;input [1:0] z;begin
 wait(dut.load_busy);cycles(2);
 if(dut.load_idx!=0 || dut.load_sector!=100 || dut.load_zoom!=z)$fatal(1,"wrong redraw file/zoom");
 ready=0;cycles(7);
end endtask
task finish_frame;input [1:0] z;input integer memory_first;begin
 if(memory_first)begin mem_toggle=~mem_toggle;cycles(8);
  if(shown==z || !dut.load_busy)$fatal(1,"committed before source completion");ready=1;
 end else begin ready=1;cycles(8);
  if(shown==z || !dut.load_busy)$fatal(1,"committed before memory completion");mem_toggle=~mem_toggle;
 end
 cycles(10);
 if(dut.load_busy || !dut.switch_wait || !valid || shown!=z)$fatal(1,"frame did not commit");
end endtask
task ack;begin reader_index=disp;reader_toggle=~reader_toggle;cycles(8);end endtask
task load_at;input [1:0] z;input [2:0] idx;input [31:0] addr;begin
 wait(dut.load_busy);cycles(2);
 if(dut.load_idx!=idx || dut.load_sector!=addr || dut.load_zoom!=z)$fatal(1,"queued navigation/zoom priority or source mismatch");
 ready=0;cycles(7);
end endtask
initial begin
 force dut.sd_init_done=initialized;force dut.scheduler_ready=ready;
 force dut.scan_done=scanned;force dut.scan_found_valid=found;force dut.scan_found_sector=sector;
 force dut.bmp_load_failed=failed;
 cycles(5);rst=0;initialized=1;cycles(8);
 found=1;cycles(1);found=0;cycles(2);sector=2000;found=1;cycles(1);found=0;scanned=1;
 start(1);ready=1;mem_toggle=~mem_toggle;cycles(10);ack;
 if(!valid || shown!=1 || launches!=1)$fatal(1,"initial frame");
 zoom=3;start(3);
 if(shown!=1 || pic!=0)$fatal(1,"requested zoom leaked before commit");
 // In-flight changes coalesce to the latest request after reader ownership ACK.
 zoom=0;cycles(2);zoom=2;finish_frame(3,1);cycles(15);
 if(dut.load_busy || launches!=2)$fatal(1,"redraw ignored reader reservation");
 reader_index=disp^1;reader_toggle=~reader_toggle;cycles(8);
 if(!dut.switch_wait || dut.load_busy)$fatal(1,"wrong-buffer ACK released writer reservation");
 ack;start(2);finish_frame(2,0);ack;cycles(10);
 if(launches!=3 || pic!=0)$fatal(1,"zoom changed picture or replayed old request");
 paused=1;cycles(5);zoom=0;cycles(20);
 if(dut.load_busy)$fatal(1,"paused redraw launched");
 paused=0;start(0);paused=1;finish_frame(0,0);ack;cycles(10);
 if(launches!=4)$fatal(1,"pause aborted in-flight redraw");
 paused=0;zoom=1;start(1);failed=1;cycles(2);paused=1;cycles(6);failed=0;ready=1;cycles(8);
 if(shown!=0 || pic!=0 || dut.load_busy)$fatal(1,"failed redraw replaced complete frame");
 paused=0;start(1);finish_frame(1,1);
 if(launches!=6)$fatal(1,"failed redraw retry count");
 // A queued explicit NEXT takes priority over redrawing the old file when
 // zoom changes while the reader has not yet acknowledged the last frame.
 force dut.key_next_press=1;cycles(1);release dut.key_next_press;zoom=3;cycles(6);
 if(!dut.next_req_pending || dut.load_busy)$fatal(1,"pending manual request lost behind reader ACK");
 ack;load_at(3,1,2000);finish_frame(3,0);ack;
 if(pic!=1 || launches!=7)$fatal(1,"zoom swallowed NEXT");
 zoom=0;load_at(0,1,2000);finish_frame(0,1);
 // The equivalent PREV/zoom collision must return to source sector 100.
 vp=~vp;cycles(8);zoom=2;cycles(3);
 if(!dut.voice_request || !dut.next_req_pending || dut.load_busy)$fatal(1,"pending voice PREV lost");
 ack;load_at(2,0,100);finish_frame(2,0);ack;
 if(pic!=0 || launches!=9)$fatal(1,"zoom swallowed PREV or added duplicate redraw");
 $display("PASS zoom scheduler: same-file redraw, both completion orders, committed status, correct/wrong reader ACK, coalesced requests, pause/failure recovery, NEXT/PREV with simultaneous zoom");$finish;
end
initial begin #100000;$fatal(1,"zoom scheduler timeout");end
endmodule

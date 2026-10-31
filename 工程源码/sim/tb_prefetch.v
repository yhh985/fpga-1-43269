`timescale 1ns/1ps
module tb_prefetch;
reg clk=0,rst=1;always #5 clk=~clk;
reg initialized=0,ready=1,scanned=0,found=0,paused=0,failed=0;
reg mem_toggle=0,reader_toggle=0,vn=0,vp=0;
reg auto_mode=0;
reg [1:0] reader_index=0,zoom=1;
reg [31:0] sector=100;
wire valid;wire [2:0] pic;wire [1:0] disp;
integer launches=0,n,before_launch;
sd_card_bmp #(.MAIN_SD_FEATURES(1),.PREFETCH_NEXT(1),.CLK_FREQ_HZ(100),.AUTO_INTERVAL_SECONDS(1)) dut(
 .clk(clk),.rst(rst),.key_next(1'b1),.auto_play_enable(auto_mode),
 .voice_next_toggle(vn),.voice_prev_toggle(vp),.audio_play_enable(1'b0),
 .playback_pause(paused),.test_mode(1'b0),.audio_next_toggle(1'b0),
 .zoom_level(zoom),.audio_clk(clk),.music_pop(1'b0),
 .music_next_toggle(1'b0),.music_prev_toggle(1'b0),
 .bmp_width(16'd640),.bmp_height(16'd480),.display_valid(valid),
 .write_finish_toggle(mem_toggle),.read_buffer_toggle(reader_toggle),.read_buffer_index(reader_index),
 .disp_buf_idx(disp),.current_pic_idx(pic),.write_req_ack(1'b1),.write_data_ready(1'b1),.SD_MISO(1'b1));
always @(posedge clk)if(!rst && dut.load_start_pulse)begin
 launches=launches+1;
 if(valid && dut.write_buf_idx==disp)$fatal(1,"overwrote visible buffer");
end
task cycles;input integer count;begin repeat(count)@(negedge clk);end endtask
task busy;begin wait(dut.load_busy);cycles(3);ready=0;cycles(8);end endtask
task complete;begin ready=1;cycles(8);if(!dut.load_busy)$fatal(1,"committed without memory ACK");
 mem_toggle=~mem_toggle;cycles(10);end endtask
task ack;begin reader_index=disp;reader_toggle=~reader_toggle;cycles(8);end endtask
initial begin
 force dut.sd_init_done=initialized;force dut.bmp_ready=ready;force dut.bmp_load_failed=failed;
 force dut.scan_done=scanned;force dut.scan_found_valid=found;force dut.scan_found_sector=sector;
 cycles(5);rst=0;initialized=1;cycles(8);
 for(n=0;n<3;n=n+1)begin sector=100+n*100;found=1;cycles(1);found=0;cycles(2);end
 scanned=1;busy;complete;
 if(!valid || pic!=0 || !dut.switch_wait)$fatal(1,"first frame failed");
 paused=1;ack;cycles(20);if(dut.load_busy)$fatal(1,"prefetched while transition owns old frame");
 paused=0;busy;
 if(!dut.prefetch_load || dut.load_idx!=1)$fatal(1,"next image not prepared");
 complete;
 if(pic!=0 || dut.switch_wait || !dut.prefetch_valid)$fatal(1,"background load changed visible image");
 before_launch=launches;vn=~vn;cycles(8);
 if(pic!=1 || !dut.switch_wait || launches!=before_launch)$fatal(1,"cache hit did not switch without SD reload");
 paused=1;ack;cycles(10);paused=0;busy;
 // A command received while prefetch is in progress must survive.
 vn=~vn;cycles(8);if(!dut.next_req_pending)$fatal(1,"busy voice command dropped");
 complete;cycles(8);
 if(pic!=2 || dut.load_busy || !dut.switch_wait)$fatal(1,"busy request not served from completed cache");
 paused=1;ack;paused=0;busy;
 // Failed speculative loads must preserve the display and stop retry loops.
 failed=1;cycles(2);failed=0;ready=1;cycles(30);
 if(pic!=2 || dut.load_busy || !dut.prefetch_failed)$fatal(1,"failed prefetch retried/changed display");
 vp=~vp;busy;
 if(dut.load_idx!=1)$fatal(1,"PREV used stale next cache");
 complete;paused=1;cycles(5);ack;
 if(pic!=1)$fatal(1,"PREV reload failed");
 paused=0;busy;complete;paused=1;
 before_launch=launches;auto_mode=1;cycles(8);paused=0;
 wait(dut.switch_wait);cycles(2);
 if(pic!=2 || launches!=before_launch)$fatal(1,"auto_mode NEXT reloaded cached frame");
 paused=1;ack;
 // Changing zoom invalidates the prepared scale, even for the same next file.
 auto_mode=0;zoom=2;cycles(8);paused=0;busy;
 if(dut.load_idx!=2 || dut.load_zoom!=2)$fatal(1,"zoom redraw used stale cache");
 complete;paused=1;ack;
 initialized=0;cycles(8);if(dut.prefetch_valid)$fatal(1,"removed card retained cache");
 $display("PASS prefetch: no SD reload on manual/auto_mode NEXT hit, queued voice during load, source+memory ACK, reader/transition reservation, PREV miss, zoom invalidation, failure and removal");$finish;
end
initial begin #100000;$fatal(1,"prefetch timeout");end
endmodule


`timescale 1ns/1ps
// Exercise the real image scheduler: music requests must survive speculative
// reads, and commit only after source + SDRAM completion and reader release.
module tb_music_prefetch;
reg clk=0,rst=1;always #5 clk=~clk;
reg initialized=0,ready=1,scanned=0,found=0,paused=0,failed=0;
reg mem_toggle=0,reader_toggle=0,audio_toggle=0,music_mode=1;
reg [1:0] reader_index=0;reg [31:0] sector=100;
wire valid;wire [2:0] pic;wire [1:0] disp;
integer n,launches=0,before_launch;
sd_card_bmp #(.MAIN_SD_FEATURES(1),.PREFETCH_NEXT(1),.CLK_FREQ_HZ(100)) dut(
 .clk(clk),.rst(rst),.key_next(1'b1),.auto_play_enable(1'b0),
 .voice_next_toggle(1'b0),.voice_prev_toggle(1'b0),.audio_play_enable(music_mode),
 .background_music_enable(1'b0),.playback_pause(paused),.test_mode(1'b0),
 .audio_next_toggle(audio_toggle),.zoom_level(2'd1),.audio_clk(clk),.music_pop(1'b0),
 .music_next_toggle(1'b0),.music_prev_toggle(1'b0),
 .bmp_width(16'd640),.bmp_height(16'd480),.display_valid(valid),
 .write_finish_toggle(mem_toggle),.read_buffer_toggle(reader_toggle),.read_buffer_index(reader_index),
 .disp_buf_idx(disp),.current_pic_idx(pic),.write_req_ack(1'b1),.write_data_ready(1'b1),.SD_MISO(1'b1));
always @(posedge clk)if(!rst && dut.load_start_pulse)begin
 launches=launches+1;
 if(valid && dut.write_buf_idx==disp)$fatal(1,"overwrote visible frame");
end
task cycles;input integer count;begin repeat(count)@(negedge clk);end endtask
task busy;begin wait(dut.load_busy);cycles(3);ready=0;cycles(8);end endtask
task complete;begin ready=1;cycles(8);
 if(!dut.load_busy)$fatal(1,"committed before memory ACK");
 mem_toggle=~mem_toggle;cycles(10);end endtask
task ack;begin reader_index=disp;reader_toggle=~reader_toggle;cycles(8);end endtask
initial begin
 force dut.sd_init_done=initialized;force dut.bmp_ready=ready;force dut.bmp_load_failed=failed;
 force dut.scan_done=scanned;force dut.scan_found_valid=found;force dut.scan_found_sector=sector;
 cycles(5);rst=0;initialized=1;cycles(8);
 for(n=0;n<3;n=n+1)begin sector=100+n*100;found=1;cycles(1);found=0;cycles(2);end
 scanned=1;busy;complete;
 if(!valid || pic!=0)$fatal(1,"initial picture missing");
 paused=1;ack;cycles(8);paused=0;busy;before_launch=launches;
 audio_toggle=~audio_toggle;cycles(8);
 if(!dut.next_req_pending)$fatal(1,"MUSIC REQUEST LOST during next-picture prefetch");
 // Coalesce multiple requests rather than jumping over two pictures.
 audio_toggle=~audio_toggle;cycles(8);
 if(pic!=0 || !dut.next_req_pending)$fatal(1,"busy event changed visible picture");
 complete;cycles(8);
 if(pic!=1 || !dut.switch_wait || launches!=before_launch)
  $fatal(1,"music did not commit completed prefetch without a reload");
 paused=1;ack;cycles(8);paused=0;busy;
 audio_toggle=~audio_toggle;cycles(8);
 if(!dut.next_req_pending)$fatal(1,"second busy music request lost");
 music_mode=0;cycles(8);
 if(dut.next_req_pending)$fatal(1,"mode exit replayed stale request");
 complete;cycles(8);
 if(pic!=1 || !dut.prefetch_valid)$fatal(1,"mode exit changed picture");
 music_mode=1;cycles(8);audio_toggle=~audio_toggle;cycles(10);
 if(pic!=2 || !dut.switch_wait)$fatal(1,"idle music request missing");
 paused=1;ack;cycles(8);paused=0;busy;
 audio_toggle=~audio_toggle;cycles(8);paused=1;cycles(8);
 if(dut.next_req_pending)$fatal(1,"pause retained music request");
 complete;cycles(8);
 if(pic!=2)$fatal(1,"paused music changed picture");
 $display("PASS music prefetch: busy requests retained/coalesced; actual picture 0->1->2; source+SDRAM completion; no reload; mode exit and pause cancel");$finish;
end
initial begin #100000;$fatal(1,"music prefetch timeout");end
endmodule

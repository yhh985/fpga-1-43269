`timescale 1ns/1ps
module tb_playlist;
reg clk=0,mclk=0,rst=1,card=0,en=0,next=0,prev=0,bg=0,auto_mode=0;
always #8 clk=~clk;always #40.667 mclk=~mclk;
wire found,ok,error;wire [31:0] fd;wire fv,fe;wire [12:0] used;wire req;wire [31:0] addr;
reg nv=0,ne=0;reg [7:0] nd=0;
reg [31:0] lbas[0:19];reg [7:0] bytes[0:10239];
integer active=0,held=0,ix=0,slot=0,k,gap=0,reads=0,checks=0,samples=0,expected_index=0;
reg checking=0;reg [31:0] expected;
sd_card_bmp #(.MAIN_SD_FEATURES(1),.CLK_FREQ_HZ(62500000)) dut(
 .clk(clk),.rst(rst),.key_next(1'b1),.audio_play_enable(en),.background_music_enable(bg),.playback_pause(1'b0),.auto_play_enable(auto_mode),.test_mode(1'b1),
 .audio_next_toggle(1'b0),.voice_next_toggle(1'b0),.voice_prev_toggle(1'b0),.music_next_toggle(next),.music_prev_toggle(prev),
 .bmp_width(16'd640),.bmp_height(16'd480),.write_finish_toggle(1'b0),.read_buffer_toggle(1'b0),.read_buffer_index(2'd0),
 .write_req_ack(1'b0),.write_data_ready(1'b1),.SD_MISO(1'b1),.audio_clk(mclk),.music_pop(1'b0),
 .music_data(fd),.music_valid(fv),.music_empty(fe),.music_used(used),.music_ok(ok),.music_error(error),.music_found(found));
assign req=dut.fs_native_req;assign addr=dut.fs_native_addr;
always @(negedge clk)begin
 nv=0;ne=0;
 if(rst||!card)begin active=0;held=0;end
 else if(active)begin
  if(gap>0)gap=gap-1;
  else if(ix<512)begin nd=bytes[slot*512+ix];nv=1;ix=ix+1;gap=3;end
  else begin ne=1;active=0;held=1;end
 end else if(held)begin if(!req)held=0;end
 else if(req)begin
  slot=-1;for(k=0;k<20;k=k+1)if(lbas[k]===addr)slot=k;
  if(slot<0)$fatal(1,"Unexpected LBA %d",addr);active=1;ix=0;gap=20;reads=reads+1;
 end
 if(checking && dut.g_fat32.pcm_valid && ok)begin
  expected={16'(-((expected_index+1)*1000+samples%200)),16'((expected_index+1)*1000+samples%200)};
  if(dut.g_fat32.pcm_frame!==expected)$fatal(1,"track%0d sample%0d got%h want%h",expected_index,samples,dut.g_fat32.pcm_frame,expected);
  samples=samples+1;checks=checks+1;
 end
end
task wait_samples;input integer n;integer cycles;begin cycles=0;while(samples<n&&cycles<100000)begin @(negedge clk);cycles=cycles+1;end
 if(samples<n||error)$fatal(1,"stream stalled/error track%0d samples%0d",expected_index,samples);end endtask
task switch_track;input integer direction,index;begin
 checking=0;@(negedge clk);if(direction)next=~next;else prev=~prev;
 wait(dut.g_fat32.switch_hold);#1;if(ok)$fatal(1,"switch not muted");
 wait(!dut.g_fat32.switch_hold);#1;
 if(dut.g_fat32.track_index!=index)$fatal(1,"wrap/index expected%0d",index);
 if(dut.g_fat32.fifo_used!=0||used!=0)$fatal(1,"old-track FIFO was not cleared");
 samples=0;expected_index=index;checking=1;
end endtask
integer i;
initial begin
 force dut.native_init_done=card;force dut.native_data=nd;force dut.native_data_valid=nv;force dut.native_read_end=ne;
 $readmemh("verification/music_fixtures/lbas.mem",lbas);$readmemh("verification/music_fixtures/sectors.mem",bytes);
 repeat(10)@(negedge clk);rst=0;card=1;wait(dut.fs_init_done);
 if(!found||dut.g_fat32.track_count!=8||dut.fs_file_count!=1)$fatal(1,"playlist cap/image enumeration");
 checking=1;bg=1;wait_samples(100);
 if(dut.selected_mode!=0)$fatal(1,"background changed manual scheduler");
 checking=0;auto_mode=1;repeat(20)@(negedge clk);
 if(dut.selected_mode!=1 || !ok)$fatal(1,"background interrupted automatic mode");
 auto_mode=0;bg=0;wait(!ok);repeat(100)@(negedge clk);
 samples=0;checking=1;en=1;wait_samples(230); // fragmented FAT chain and automatic repeat
 // Start a read and switch while native bytes are in flight.
 wait(active&&ix>50&&ix<400);switch_track(1,1);wait_samples(220);
 // Simulate a real BMP sector read occupying the filesystem across the
 // track-index change. The old fixed 16-clock delay restarts stale audio.
 checking=0;
 fork
  begin
   wait(dut.g_fat32.switch_state==2);
   force dut.sd_sec_read_addr=32'd2048;
   force dut.sd_sec_read=1'b1;
   wait(dut.fs_read_end);@(negedge clk);release dut.sd_sec_read;release dut.sd_sec_read_addr;
  end
  begin switch_track(1,2);end
  begin
   wait(dut.g_fat32.track_index==2);repeat(40)@(negedge clk);
   if(dut.g_fat32.active_track==2 || !dut.g_fat32.switch_hold)
    $fatal(1,"filesystem busy regression did not hold restart until track acknowledgement");
  end
 join
 wait_samples(50);switch_track(0,1);wait_samples(50);
 // Previous at first wraps to eighth; invalid WAV remains muted, next recovers.
 switch_track(0,0);wait_samples(50);switch_track(0,7);checking=0;wait(error);#1;if(ok)$fatal(1,"invalid WAV audible");
 switch_track(1,0);wait_samples(100);
 checking=0;en=0;wait(!ok);repeat(3000)@(negedge clk);samples=0;checking=1;en=1;wait_samples(100);
 checking=0;card=0;repeat(10)@(negedge clk);if(ok||found)$fatal(1,"card removal state");
 card=1;wait(dut.fs_init_done);samples=0;checking=1;wait_samples(100);
 $display("PASS playlist: %0d exact PCM frames / %0d sector reads; cap8, fragmented WAV, loops, NEXT/PREV/wrap, in-flight switch drain, concurrent BMP read waits for track ACK, invalid-format recovery, mode exit/reentry, card remount",checks,reads);$finish;
end
initial begin #20000000;$fatal(1,"playlist timeout state=%0d samples=%0d req=%b",dut.g_fat32.switch_state,samples,req);end
endmodule



`timescale 1ns/1ps
// Production SD wrapper (including native-byte staging, session reset and
// FIFO write wiring) + serial transmitter + existing receiver. Only native
// CRC-checked sector transport and image-sector requests are modeled.
module tb_sd_music_stream;
parameter MODEL_DIV=1; // Native sector-service model only; audio/video clocks remain physical.
parameter SD_HALF_PERIOD_NS=8; // 62.5 MHz production SD/scaler domain.
parameter FAST_DIV=0, RELEASE_CYCLES=4;
reg clk=0,mclk=0,vclk=0;always #(SD_HALF_PERIOD_NS*MODEL_DIV) clk=~clk;always #40.667 mclk=~mclk;always #20 vclk=~vclk;
reg rst=1,card=0,en=0,paused=0;
wire mounted,fs_error,found;wire [31:0] wav_bytes;
wire [3:0] files;wire [31:0] last_sector;
wire freq,fvalid,fend,nreq;wire [31:0] faddr,naddr;wire [7:0] fdata;
reg nvalid=0,nend=0;reg [7:0] ndata;
reg image_req=0;reg [31:0] image_addr=2048;wire [7:0] image_data;wire image_valid,image_end;
wire areq,avalid,aend,pcm_valid,stream_ok,wav_error;wire [31:0] aaddr,pcm_frame;wire [7:0] adata;
wire full,empty,fifo_valid,pop;wire [31:0] fifo_data;wire [12:0] wu,ru;
wire bclk,lrck,dout,playing,underflow,audio_valid;wire [15:0] underruns;wire [23:0] left,right;
reg [31:0] lbas[0:31];reg [7:0] sectors[0:16383];reg [31:0] expected[0:2047];
integer active=0,hold_req=0,byte_no=0,slot=0,gap=0,k,reads=0,image_bytes=0,image_reads=0;
integer produced=0,received=0,nonzero=0,serial_checks=0;integer timeout=0;
reg [31:0] current=0,completed=0;reg [31:0] previous_produced=0;
sd_card_bmp #(.MAIN_SD_FEATURES(1),.CLK_FREQ_HZ(62_500_000),.SPI_HIGH_SPEED_DIV(FAST_DIV),.READ_RELEASE_CYCLES(RELEASE_CYCLES)) media(
 .clk(clk),.rst(rst),.key_next(1'b1),.audio_play_enable(en),.playback_pause(paused),
 .auto_play_enable(1'b0),.test_mode(1'b1),.audio_next_toggle(1'b0),
 .bmp_width(16'd640),.bmp_height(16'd480),.write_finish_toggle(1'b0),
 .read_buffer_toggle(1'b0),.read_buffer_index(2'd0),.write_req_ack(1'b0),
 .write_data_ready(1'b1),.SD_MISO(1'b1),.audio_clk(mclk),.music_pop(pop),
 .music_data(fifo_data),.music_valid(fifo_valid),.music_empty(empty),
 .music_used(ru),.music_ok(stream_ok),.music_error(wav_error),.music_found(found));
assign mounted=media.fs_init_done;assign fs_error=media.fs_error;
assign files=media.fs_file_count;assign last_sector=media.fs_last_sector;
assign nreq=media.fs_native_req;assign naddr=media.fs_native_addr;
assign image_data=media.fs_data;assign image_valid=media.fs_data_valid;assign image_end=media.fs_read_end;
assign pcm_valid=media.g_fat32.pcm_valid;assign pcm_frame=media.g_fat32.pcm_frame;
assign wu=media.g_fat32.fifo_used;assign full=media.g_fat32.fifo_full;
audio_wav_i2s #(.SLOT_BITS(32)) tx(.mclk(mclk),.rst(rst),.enable(en),.paused(paused),.stream_ok(stream_ok),
 .fifo_used(ru),.fifo_empty(empty),.fifo_valid(fifo_valid),.fifo_data(fifo_data),.fifo_re(pop),
 .bclk(bclk),.lrck(lrck),.dout(dout),.playing(playing),.underflow(underflow),.underruns(underruns));
I2S_receiver #(.SLOT_BITS(32)) rx(.I_clk(vclk),.I_rst(rst),.I_i2s_BCLK(bclk),.I_i2s_LRCK(lrck),.I_i2s_DOUT(dout),
 .O_audio_valid(audio_valid),.O_audio_left_data(left),.O_audio_right_data(right));
always @(negedge clk)begin
 nvalid=0;nend=0;
 if(rst||!card)begin active=0;hold_req=0;end
 else if(active)begin
  if(gap!=0)gap=gap-1;
  else if(byte_no<512)begin ndata=sectors[slot*512+byte_no];nvalid=1;byte_no=byte_no+1;gap=(RELEASE_CYCLES-1)/MODEL_DIV;end
  else begin nend=1;active=0;hold_req=1;end
 end else if(hold_req)begin if(!nreq)hold_req=0;end
 else if(nreq)begin
  slot=-1;for(k=0;k<32;k=k+1)if(lbas[k]===naddr)slot=k;
  if(slot<0)$fatal(1,"out-of-range LBA %0d",naddr);
  // Model the entire SPI/CRC acquisition before buffered delivery. At DIV=2
  // it takes about 36600 source clocks, at DIV=0 about 19544 clocks.
  // MODEL_DIV rounds release upwards, making this service model conservative.
  active=1;byte_no=0;gap=(19544+8528*FAST_DIV)/MODEL_DIV;reads=reads+1;
 end
 if(pcm_valid&&stream_ok)begin
  if(full||pcm_frame!==expected[produced%2048])$fatal(1,"PCM source lost frame %0d got=%h",produced,pcm_frame);
  produced=produced+1;
 end
 if(image_valid)begin
  if(image_data!==((image_bytes*7+11)%256))$fatal(1,"audio payload leaked into image");image_bytes=image_bytes+1;
 end
 if(image_end)begin if(image_bytes!=512)$fatal(1,"image sector length");image_bytes=0;image_reads=image_reads+1;image_req=0;end
end
// Independent FIFO dequeue scoreboard verifies order, including pointer wrap.
integer consumed=0;
always @(posedge mclk)begin #1;
 if(!stream_ok)consumed=0;
 else if(fifo_valid)begin if(fifo_data!==expected[consumed%2048])$fatal(1,"FIFO reorder %0d",consumed);consumed=consumed+1;end
end
always @(negedge lrck)begin #1;if(!rst)begin completed=current;current={tx.right_word[31:16],tx.shift[63:48]};end end
always @(posedge vclk)begin #2;
 if(!rst&&audio_valid)begin
  if(left!=={completed[15:0],8'd0}||right!=={completed[31:16],8'd0})$fatal(1,"serial stereo mismatch L=%h R=%h expected=%h",left,right,completed);
  received=received+1;serial_checks=serial_checks+1;if(left||right)nonzero=nonzero+1;
 end
 if(fs_error||wav_error)$fatal(1,"music file error");
end
task wait_samples;input integer n;integer target;begin target=received+n;while(received<target)@(negedge vclk);end endtask
integer held;
initial begin
 force media.native_init_done=card;force media.native_data=ndata;
 force media.native_data_valid=nvalid;force media.native_read_end=nend;
 force media.sd_sec_read=image_req;force media.sd_sec_read_addr=image_addr;
 for(k=0;k<32;k=k+1)lbas[k]=32'hffffffff;
 $readmemh("verification/legacy_fixtures/sd_music_20261010/verification/music_lbas.mem",lbas);
 $readmemh("verification/legacy_fixtures/sd_music_20261010/verification/music_sectors.mem",sectors);
 $readmemh("verification/legacy_fixtures/sd_music_20261010/verification/expected_frames.mem",expected);
 #1;rst=1;repeat(10)@(negedge clk);rst=0;card=1;
 wait(mounted);if(!found||files!=1||last_sector!=2049)$fatal(1,"WAV polluted BMP enumeration");en=1;
 wait(playing);wait_samples(20);
 repeat(10)begin @(negedge clk);image_req=1;wait(image_end);repeat(1000)@(negedge clk);end
 wait_samples(5000);if(underruns||nonzero<4900||image_reads!=10)$fatal(1,"concurrent playback underflow or no sound");
 paused=1;wait_samples(5);held=consumed;wait_samples(40);
 if(consumed!=held||left||right)$fatal(1,"pause consumed PCM or emitted sound");
 paused=0;wait_samples(100);if(underruns)$fatal(1,"resume underflow");
 // Force a long card stall. It must output zero, count once, then rebuffer.
 force nreq=0; // prevents new transactions, in-flight read safely finishes
 wait(!playing);wait_samples(5);if(!underflow||underruns!=1||left||right)$fatal(1,"underrun behavior");
 release nreq;wait(playing);wait_samples(50);if(underruns!=1)$fatal(1,"rebuffer repeatedly counted underrun");
 // Disable during an in-flight audio sector; reentry must start at first PCM.
 wait(media.g_fat32.u_music_reader.state==1);en=0;wait_samples(5);produced=0;
 wait(media.g_fat32.u_music_reader.state==0);en=1;wait(playing);wait_samples(50);
 if(wav_error||fs_error)$fatal(1,"mode restart error");
 card=0;wait_samples(5);if(mounted||left||right)$fatal(1,"card loss did not mute");
 $display("PASS SD music integration: %0d serial stereo frames, actual SD wrapper/native staging/session reset, fragmented WAV loop, FIFO order/wrap, 10 interleaved image sectors, pause/resume, underrun/rebuffer, in-flight exit/restart, card loss; %0d native reads",serial_checks,reads);$finish;
end
initial begin #500000000;$fatal(1,"music integration timeout state=%0d",media.g_fat32.u_music_reader.state);end
endmodule

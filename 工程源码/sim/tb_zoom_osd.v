`timescale 1ns/1ps
module tb_zoom_osd;
reg clk=0,rst=1,vs=1;always #5 clk=~clk;
reg [1:0] zoom=1;integer z,c;reg [31:0] label_text;
wire [23:0] rgb;
osd_status_overlay #(.ZOOM_STATUS(1)) dut(.I_clk(clk),.I_rst(rst),.I_vs(vs),.I_hs(1'b0),.I_de(1'b0),
 .I_rgb(24'd0),.I_zoom_level(zoom),.I_music_status(4'd0),.I_img_idx(7'd0),.I_src_w(16'd640),.I_src_h(16'd480),
 .I_src_valid(1'b1),.I_filter_mode(3'd0),.I_auto_play(1'b0),.I_playback_mode(2'd0),.I_paused(1'b0),
 .I_trans_active(1'b0),.I_trans_alpha(5'd0),.I_state_code(4'd0),.I_sd_error(1'b0),.I_sd_error_code(4'd0),
 .I_sd_last_cmd(6'd0),.I_sd_last_r1(8'd0),.I_osd_en(1'b1),.I_test_mode(1'b0),.O_rgb_out(rgb));
initial begin
 repeat(3)@(negedge clk);rst=0;
 for(z=0;z<4;z=z+1)begin
  zoom=z;repeat(3)@(negedge clk);
  if(dut.zoom_frame!=(z==0 ? 1 : z-1))$fatal(1,"status changed within a frame");
  vs=0;repeat(2)@(negedge clk);vs=1;repeat(2)@(negedge clk);
  if(dut.width_digits!==16'h0640 || dut.height_digits!==16'h0480)$fatal(1,"dimension BCD snapshot mismatch");
  case(z)0:label_text="X0.5";1:label_text="X1.0";2:label_text="X1.5";3:label_text="X2.0";endcase
  for(c=0;c<4;c=c+1)begin
   force dut.resolution_char_idx=14+c;#1;
   if(dut.resolution_char!==label_text[31-c*8-:8])$fatal(1,"incorrect zoom label");
  end
  release dut.resolution_char_idx;
 end
 if(dut.glyph_row(".",6)!==5'b00100 || dut.glyph_row(".",0)!==0)$fatal(1,"decimal point glyph missing");
 if(dut.glyph_row("X",0)!==5'b10001 || dut.glyph_row("5",0)!==5'b11111)$fatal(1,"zoom glyphs missing");
 $display("PASS zoom OSD: four exact labels and visible decimal point, changes latched only at frame boundary");$finish;
end
endmodule

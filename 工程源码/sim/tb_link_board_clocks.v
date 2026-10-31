`timescale 1ns/1ps
// Board defaults, independent oscillators and staggered configuration release.
module tb_link_board_clocks;
 reg aca_clk=0,hx_clk=0,aca_rst=1,hx_rst=1;
 always #10 aca_clk=~aca_clk;
 always #10.05 hx_clk=~hx_clk; // 0.5% oscillator mismatch, unrelated phase.
 reg disconnect_return=0;
 reg [255:0] status=0;
 wire aca_tx,hx_tx,aca_online,hx_online,status_valid,voice_enable;
 wire [255:0] host_status;
 wire [15:0] aca_crc,hx_crc;
 link_sensor aca(.clk(aca_clk),.rst(aca_rst),
  .rx(disconnect_return?1'b1:hx_tx),.tx(aca_tx),.status(status),
  .event_valid(1'b0),.event_command(8'd0),.online(aca_online),
  .event_failed(),.queue_overflow(),.crc_errors(aca_crc),
  .host_voice_enable(voice_enable));
 link_host hx(.clk(hx_clk),.rst(hx_rst),.rx(aca_tx),.tx(hx_tx),
  .voice_allow(hx_online && host_status[15]),.online(hx_online),
  .command_valid(),.command(),.music_valid(),.music_command(),
  .status_valid(status_valid),.status(host_status),.crc_errors(hx_crc));
 initial begin
  #1000; @(negedge aca_clk); aca_rst=0;
  #1000000; @(negedge hx_clk); hx_rst=0;
  wait(status_valid); #1;
  if(!aca_online || !hx_online || aca_crc || hx_crc)
   $fatal(1,"board-default startup failed");
  @(negedge aca_clk); status[15]=1;
  wait(voice_enable);
  $display("PASS independent board clocks: default prescale=54, 0.5%% clock mismatch, staggered boot, status and voice permission");
  // HX must be able to recover while ACA retains its previous session.
  @(negedge hx_clk); hx_rst=1;
  repeat(10) @(negedge hx_clk); hx_rst=0;
  wait(!aca.ready_session); wait(aca.ready_session);
  wait(voice_enable);
  if(!aca_online || !hx_online || aca_crc || hx_crc)
   $fatal(1,"host restart failed");
  $display("PASS independent board clocks: HX-only restart restores session and voice permission");
  $finish;
 end
 initial begin #400000000; $fatal(1,"board-default communication watchdog"); end
endmodule

`timescale 1ns/1ps
module tb_music_clock_probe;
 reg clk=0,rst=1,b=0,l=0;
 always #10 clk=~clk;
 wire [1:0] code;
 wire valid;
 aca_music_clock_probe dut(.clk(clk),.rst(rst),.bclk(b),.lrck(l),.code(code),.valid(valid));
 reg source_bclk=0,source_lrck=0;
 integer source_bits=0;
 always #160 begin
  source_bclk=~source_bclk;
  if(!source_bclk)begin
   if(source_bits==31)begin source_bits=0;source_lrck=~source_lrck;end
   else source_bits=source_bits+1;
  end
 end
 wire [1:0] swapped_code;
 aca_music_clock_probe swapped(.clk(clk),.rst(rst),.bclk(source_lrck),
  .lrck(source_bclk),.code(swapped_code));
 reg interchange=0,drop_bclk=0;
 wire rb=drop_bclk?1'b0:(interchange?source_lrck:source_bclk);
 wire rl=interchange?source_bclk:source_lrck;
 wire selected_b,selected_l,autofix,changed;
 wire [1:0] routed_code;
 aca_music_clock_route route(.clk(clk),.rst(rst),.pin_bclk(rb),.pin_lrck(rl),
  .selected_bclk(selected_b),.selected_lrck(selected_l),.swapped(autofix),
  .changed(changed),.code(routed_code));
 integer changes=0;
 always @(posedge clk)if(changed)changes=changes+1;
 initial begin
  wait(!rst);#150000;
  if(autofix || routed_code!==0)$fatal(1,"normal clock order changed");
  interchange=1;#150000;
  if(!autofix || selected_b!==source_bclk || selected_l!==source_lrck)
   $fatal(1,"reverse order was not recovered");
  interchange=0;#150000;
  if(autofix)$fatal(1,"normal order was not restored");
  drop_bclk=1;#150000;
  if(autofix || routed_code!==1)$fatal(1,"missing BCLK falsely corrected");
  drop_bclk=0;#150000;
  if(autofix || routed_code!==0 || changes!=2)$fatal(1,"unstable route or failed recovery");
 end
 task slot;input integer bits;integer i;begin
  for(i=0;i<bits;i=i+1)begin
   #160;b=1;#160;b=0;
  end
  #35;l=~l;
 end endtask
 task check;input integer bits;input [1:0] expected;integer i;begin
  for(i=0;i<12;i=i+1)slot(bits);
  #100;if(code!==expected)$fatal(1,"bits=%0d code=%0d expected=%0d",bits,code,expected);
 end endtask
 integer i;
 initial begin
  #51;rst=0;
  check(32,0);check(64,2);check(16,3);check(0,1);
  if(swapped_code!==1)$fatal(1,"actual BCLK/LRCK interchange was not diagnosed");
  check(32,0);
  // A few bad intervals must not overwrite a settled diagnosis.
  for(i=0;i<3;i=i+1)slot(64);
  #100;if(code!==0)$fatal(1,"transient slot error changed settled code");
  check(300,3); // Saturated count still diagnoses malformed traffic.
  repeat(1048600)@(negedge clk);
  if(code!==0 || valid)$fatal(1,"stale diagnosis did not expire");
  check(32,0);
  $display("PASS clock probe: 32/64/16/zero/overflow, glitch rejection, idle expiry/recovery, auto-route normal/swapped/restored/missing BCLK");$finish;
 end
 initial begin #100000000;$fatal(1,"clock probe timeout");end
endmodule

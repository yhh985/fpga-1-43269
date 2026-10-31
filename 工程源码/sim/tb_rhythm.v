`timescale 1ns/1ps
module tb_rhythm;
 reg clk=0,rst=1,tap=0,learn=0,clear=0;reg [1:0] slot=0;
 always #5 clk=~clk;
 wire learning,event_valid,rejected,lp;wire [2:0] learned,progress;wire [1:0] command;wire [7:0] confidence;
 aca_rhythm #(.MS_CYCLES(1),.COOLDOWN_MS(100)) dut(.clk(clk),.rst(rst),.tap(tap),.learn(learn),.clear(clear),.slot(slot),
 .learning(learning),.learned(learned),.progress(progress),.event_valid(event_valid),.event_command(command),.confidence(confidence),.rejected(rejected),.learned_pulse(lp));
 integer events=0,rejects=0,last=0;
 always @(posedge clk)begin #1;if(event_valid)begin events=events+1;last=command;end if(rejected)rejects=rejects+1;end
 task beat;begin @(negedge clk);tap=1;@(negedge clk);tap=0;end endtask
 task gesture;input integer a,b,c;begin beat();repeat(a-2)@(negedge clk);beat();repeat(b-2)@(negedge clk);beat();repeat(c-2)@(negedge clk);beat();repeat(120)@(negedge clk);end endtask
 task start_learn;input [1:0] n;begin @(negedge clk);slot=n;learn=1;@(negedge clk);learn=0;end endtask
 initial begin
  repeat(5)@(negedge clk);rst=0;
  start_learn(0);gesture(300,300,300);if(learned!=1 || learning)$fatal(1,"learn slot0");
  gesture(200,200,200);if(events!=1 || last!=1)$fatal(1,"faster tempo");
  gesture(450,450,450);if(events!=2 || last!=1)$fatal(1,"slower tempo");
  start_learn(1);gesture(200,200,600);gesture(300,300,900);if(events!=3 || last!=2)$fatal(1,"slot1 normalized");
  gesture(600,150,150);if(events!=3 || rejects==0)$fatal(1,"reject wrong rhythm");
  start_learn(2);gesture(300,300,300);gesture(300,300,300);if(events!=3)$fatal(1,"ambiguous match must reject");
  @(negedge clk);clear=1;@(negedge clk);clear=0;gesture(300,300,300);if(events!=4 || learned!=3)$fatal(1,"clear template");
  beat();repeat(2000)@(negedge clk);if(progress!=0)$fatal(1,"timeout reset");
  start_learn(0);beat();start_learn(0);if(learning || progress!=0)$fatal(1,"cancel learning");
  $display("PASS rhythm: learn, tempo x0.67/x1.5, 3 slots, ambiguity, wrong pattern, clear, timeout, cancel");$finish;
 end
 initial begin #3000000;$fatal(1,"rhythm watchdog");end
endmodule

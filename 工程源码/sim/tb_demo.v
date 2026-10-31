`timescale 1ns/1ps
module tb_demo;
 reg clk=0,rst=1,enable=0,learn=0;reg [1:0] slot=0;
 always #5 clk=~clk;
 wire tap,sv,learning,ev;wire signed [15:0] sample;wire [2:0] learned,progress;wire [1:0] command;
 aca_demo #(.MS_CYCLES(1),.SAMPLE_CYCLES(2)) demo(.clk(clk),.rst(rst),.enable(enable),.slot(slot),.sample_valid(sv),.sample(sample),.tap(tap));
 aca_rhythm #(.MS_CYCLES(1)) rhythm(.clk(clk),.rst(rst),.tap(tap),.learn(learn),.clear(1'b0),.slot(slot),.learning(learning),.learned(learned),.progress(progress),.event_valid(ev),.event_command(command),.confidence(),.rejected(),.learned_pulse());
 integer k,events=0,last=0;
 always @(posedge clk)begin #1;if(ev)begin events=events+1;last=command;end end
 initial begin
  repeat(5)@(negedge clk);rst=0;
  for(k=0;k<3;k=k+1)begin
   enable=0;slot=k;repeat(3)@(negedge clk);learn=1;@(negedge clk);learn=0;enable=1;
   wait(!learning);if(!learned[k])$fatal(1,"demo learning slot%0d",k);
   wait(events==k+1);if(last!=k+1)$fatal(1,"demo recognizer slot%0d command%0d",k,last);
  end
  enable=0;repeat(10)@(negedge clk);
  if(tap || sv)$fatal(1,"disabled demo");
  $display("PASS demo -> real rhythm learner/matcher: all 3 slots and commands, no recognizer bypass");$finish;
 end
 initial begin #1000000;$fatal(1,"demo watchdog");end
endmodule

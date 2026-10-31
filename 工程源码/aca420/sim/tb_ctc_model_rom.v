`timescale 1ns/1ps
module tb_ctc_model_rom;
reg clk=0; always #5 clk=~clk;
wire result_valid,event_valid,fault,window_ready,quiet_ready,utterance_active,processing,rejected_pulse;
wire [1:0] result_class,event_command;
wire [7:0] reject_flags;
wire [15:0] debug_sequence;
wire [6:0] debug_voiced,debug_duration;
wire [287:0] debug_logits;
aca_ctc_engine #(.MODEL_DIR("../voice/model_ctc/")) dut(
 .clk(clk),.rst(1'b1),.feature_valid(1'b0),.feature_index(4'b0),.feature_data(8'sd0),
 .feature_active(1'b0),.frame_done(1'b0),.result_valid(result_valid),.result_class(result_class),
 .event_valid(event_valid),.event_command(event_command),.fault(fault),.window_ready(window_ready),
 .quiet_ready(quiet_ready),.utterance_active(utterance_active),.processing(processing),
 .rejected_pulse(rejected_pulse),.reject_flags(reject_flags),.debug_sequence(debug_sequence),
 .debug_voiced(debug_voiced),.debug_duration(debug_duration),.debug_logits(debug_logits));
initial begin
 #1;
 if(dut.weights[0]!==8'hf2 || dut.biases[0]!==-32'sd34 || dut.shifts[0]!==8'h0a ||
    dut.logadd_rom[0]!==8'h2c || dut.codes[0]!==8'h00 || dut.lengths[0]!==8'h07 || dut.commands[0]!==8'h02)
  $fatal(1,"CTC model ROM missing or loaded from wrong path");
 $display("PASS CTC model ROM relative-path load"); $finish;
end
endmodule

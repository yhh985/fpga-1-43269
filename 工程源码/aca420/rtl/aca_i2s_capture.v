`timescale 1ns/1ps
// I2S framing and stable-data/toggle transfer informed by the public
// electronic-circuit/audio_pcm_bridge.v; independent implementation.
// All serial work uses MCLK clock enables, not a fabric BCLK clock tree.
module aca_i2s_capture (
    input wire mclk, input wire audio_rst_n, input wire enable,
    input wire adcdat,
    output wire bclk, output wire lrck,
    output reg signed [15:0] left_hold, right_hold,
    output reg pair_toggle
);
    reg [7:0] phase;
    reg [15:0] shift;
    reg pending_toggle;
    reg frame_armed;
    reg adc_sample;
    assign bclk=phase[1];
    assign lrck=phase[7];
    wire [4:0] slot_bit=phase[6:2];
    wire rising_bit=phase[1:0]==2'b01;
    // Sample midway between MCLK edges, 1.5 MCLK periods after the
    // preceding BCLK fall. This leaves both codec settling and IO hold margin.
    always @(negedge mclk or negedge audio_rst_n) begin
        if(!audio_rst_n) adc_sample<=0;
        else if(rising_bit) adc_sample<=adcdat;
    end
    always @(posedge mclk or negedge audio_rst_n) begin
        if(!audio_rst_n) begin
            phase<=0; shift<=0; left_hold<=0; right_hold<=0;
            pair_toggle<=0; pending_toggle<=0;
            frame_armed<=0;
        end else begin
            phase<=phase+1'b1;
            pending_toggle<=0;
            if(pending_toggle) pair_toggle<=~pair_toggle;
            if(!enable) begin shift<=0; frame_armed<=0; end
            else if(rising_bit) begin
                // LRCK changes at slot bit 0: discard the one-bit I2S delay.
                if(slot_bit==0) begin
                    shift<=0;
                    if(!phase[7]) frame_armed<=1;
                end
                else if(slot_bit<=16 && frame_armed) begin
                    shift<={shift[14:0],adc_sample};
                    if(slot_bit==16) begin
                        if(!phase[7]) left_hold<={shift[14:0],adc_sample};
                        else begin
                            right_hold<={shift[14:0],adc_sample};
                            pending_toggle<=1; // Publish one MCLK after stable data.
                        end
                    end
                end
            end
        end
    end
endmodule

module aca_pcm_mailbox (
    input wire clk, input wire rst_n,
    input wire source_toggle,
    input wire signed [15:0] source_left, source_right,
    output reg valid,
    output reg signed [15:0] left, right
);
    // One source update per ~20.8 us; capture latency <= 4*20 ns.
    // Source bus remains stable until the next complete stereo pair.
    (* async_reg="true", syn_preserve=1 *) reg [2:0] sync_toggle;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin sync_toggle<=0; valid<=0; left<=0; right<=0; end
        else begin
            sync_toggle<={sync_toggle[1:0],source_toggle};
            valid<=sync_toggle[2]^sync_toggle[1];
            if(sync_toggle[2]^sync_toggle[1]) begin
                left<=source_left; right<=source_right;
            end
        end
    end
endmodule

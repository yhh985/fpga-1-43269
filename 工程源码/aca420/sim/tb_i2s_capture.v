`timescale 1ns/1ps
module tb_i2s_capture;
    reg mclk=0, clk=0, rst_n=0, enable=0, data=0;
    always #40.666667 mclk=~mclk;
    always #10 clk=~clk;
    wire bclk, lrck, toggle, valid;
    wire signed [15:0] sl, sr, left, right;
    aca_i2s_capture u_serial(.mclk(mclk),.audio_rst_n(rst_n),.enable(enable),
        .adcdat(data),.bclk(bclk),.lrck(lrck),.left_hold(sl),.right_hold(sr),.pair_toggle(toggle));
    aca_pcm_mailbox u_mailbox(.clk(clk),.rst_n(rst_n),.source_toggle(toggle),
        .source_left(sl),.source_right(sr),.valid(valid),.left(left),.right(right));
    // External ADC model tracks only BCLK/LRCK, independently of DUT phase.
    integer bit_number=-1, pair_number=0, checked=0;
    reg previous_lrck=1, previous_valid=0;
    reg [15:0] expected_left[0:199], expected_right[0:199];
    function [15:0] lword;
        input integer n;
        begin case(n%6)
            0:lword=16'h8000; 1:lword=16'h7fff; 2:lword=16'ha55a;
            3:lword=16'h0001; 4:lword=16'hffff; default:lword=16'h1234;
        endcase end
    endfunction
    function [15:0] rword;
        input integer n;
        begin rword=16'h5aa5^(n*129); end
    endfunction
    reg [15:0] word;
    always @(negedge bclk or negedge rst_n) begin
        if(!rst_n) begin bit_number=-1; previous_lrck=1; pair_number=0; data=0; end
        else begin
            if(lrck!=previous_lrck) begin
                bit_number=0; previous_lrck=lrck;
                if(!lrck) begin
                    expected_left[pair_number]=lword(pair_number);
                    expected_right[pair_number]=rword(pair_number);
                end
            end else bit_number=bit_number+1;
            word=lrck ? rword(pair_number):lword(pair_number);
            if(bit_number>=1 && bit_number<=16) data=word[16-bit_number];
            else data=bit_number[0]; // Padding garbage must not enter the PCM.
            if(lrck && bit_number==31) pair_number=pair_number+1;
        end
    end
    integer expected_index=0;
    reg aligned=0;
    always @(posedge clk) begin
        #1;
        if(valid) begin
            if(previous_valid) $fatal(1,"valid lasted more than one sys clock");
            // Enabling in mid-frame discards the incomplete pair.
            if(!aligned) begin
                if(left!==lword(pair_number) || right!==rword(pair_number))
                    $fatal(1,"first pair is incomplete: %h %h model pair %0d",left,right,pair_number);
                expected_index=pair_number; aligned=1;
            end
            if(left!==lword(expected_index) || right!==rword(expected_index))
                $fatal(1,"pair %0d got %h/%h expected %h/%h",expected_index,left,right,lword(expected_index),rword(expected_index));
            expected_index=expected_index+1; checked=checked+1;
        end
        previous_valid=valid;
    end
    initial begin
        #1; rst_n=0; #150; rst_n=1;
        #13500; enable=1;
        wait(checked==60);
        @(negedge clk); enable=0;
        #50000;
        if(valid) $fatal(1,"valid while disabled");
        // Mid-run reset exercises both domains and polarity alignment.
        @(negedge clk); rst_n=0; aligned=0; previous_valid=0;
        #500; rst_n=1; #18000; enable=1;
        wait(checked==120);
        $display("PASS I2S: 120 independent stereo pairs, padding, signed extremes, mid-slot enable, restart");
        $finish;
    end
    initial begin #10000000; $fatal(1,"I2S timeout"); end
endmodule

`timescale 1ns/1ps
module tb_audio_goertzel;
    parameter integer BANDS=4;
    localparam integer INDEX_WIDTH=(BANDS==8)?3:2;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, sample_valid = 0;
    reg signed [15:0] sample_in = 0;
    wire sample_ready, sample_overrun, result_valid, result_overflow, event_pulse;
    wire [INDEX_WIDTH-1:0] peak_index;
    wire [15:0] peak_frequency, sample_count;
    wire [31:0] peak_power, power0, power1, power2, power3;
    wire [31:0] power4,power5,power6,power7;
    integer errors=0, n, i, timeout_count, sample_value;
    reg [255:0] held_powers;
    real tone_frequency, reference_real, reference_imag, reference_power, relative_error;
    integer accepted_in_window=0, cycles=0, last_accept_cycle=0;
    // End-to-end protocol check: exactly 1024 accepted samples per result and
    // the final serial computation has a fixed 29-clock latency.
    always @(posedge clk) begin
        if(rst) begin accepted_in_window=0;cycles=0;last_accept_cycle=0;end
        else begin
            cycles=cycles+1;
            if(sample_valid && sample_ready) begin
                accepted_in_window=accepted_in_window+1;
                last_accept_cycle=cycles;
            end
            #1;
            if(result_valid) begin
                if(accepted_in_window!=1024 || cycles-last_accept_cycle!=7*BANDS+1) begin
                    $display("FAIL window protocol accepted=%0d latency=%0d",accepted_in_window,cycles-last_accept_cycle);
                    errors=errors+1;
                end
                accepted_in_window=0;
            end
        end
    end
    audio_goertzel #(.BAND_COUNT(BANDS),.POWER_WIDTH(BANDS==8?24:32),
        .POWER_SHIFT(BANDS==8?25:17),.EVENT_THRESHOLD(BANDS==8?16:4096),
        .COEFF0(BANDS==8?131033:130995),.COEFF1(BANDS==8?130914:130950),
        .COEFF2(BANDS==8?130441:130899),.COEFF3(BANDS==8?128553:130765),
        .FREQUENCY0(BANDS==8?188:262),.FREQUENCY1(BANDS==8?375:330),
        .FREQUENCY2(BANDS==8?750:392),.FREQUENCY3(BANDS==8?1500:523)
    ) dut (
        .clk(clk), .rst(rst), .sample_valid(sample_valid), .sample_in(sample_in),
        .sample_ready(sample_ready), .sample_overrun(sample_overrun),
        .result_valid(result_valid), .result_overflow(result_overflow),
        .event_pulse(event_pulse), .peak_index(peak_index), .peak_frequency(peak_frequency),
        .peak_power(peak_power), .power0(power0), .power1(power1), .power2(power2),
        .power3(power3),.power4(power4),.power5(power5),.power6(power6),.power7(power7),
        .sample_count(sample_count)
    );
    task send_sample;
        input integer value;
        begin
            while (!sample_ready) @(negedge clk);
            @(negedge clk); sample_in=value; sample_valid=1;
            @(negedge clk); sample_valid=0; sample_in=0;
        end
    endtask
    task await_result;
        begin
            timeout_count=0;
            while (!result_valid && timeout_count<70) begin
                @(negedge clk); timeout_count=timeout_count+1;
            end
            if (!result_valid) begin $display("FAIL missing completed window"); errors=errors+1; end
        end
    endtask
    task tone_window;
        input integer expected_index;
        input integer amplitude;
        begin
            if(BANDS==8) case(expected_index)
                0:tone_frequency=187.5;1:tone_frequency=375;2:tone_frequency=750;
                3:tone_frequency=1500;4:tone_frequency=3000;5:tone_frequency=6000;
                6:tone_frequency=9000;default:tone_frequency=12000;
            endcase
            else case(expected_index)
                0: tone_frequency=261.63;
                1: tone_frequency=329.63;
                2: tone_frequency=392.0;
                default: tone_frequency=523.25;
            endcase
            reference_real=0.0; reference_imag=0.0;
            for(n=0;n<1024;n=n+1) begin
                sample_value=$rtoi(amplitude*$sin(2.0*3.141592653589793*tone_frequency*n/48000.0));
                reference_real=reference_real+sample_value*$cos(2.0*3.141592653589793*tone_frequency*n/48000.0);
                reference_imag=reference_imag+sample_value*$sin(2.0*3.141592653589793*tone_frequency*n/48000.0);
                send_sample(sample_value);
            end
            await_result;
            if (peak_index !== expected_index[INDEX_WIDTH-1:0] || !event_pulse || result_overflow || peak_power==0) begin
                $display("FAIL tone=%0f amplitude=%0d peak=%0d power=%0d overflow=%b event=%b",tone_frequency,amplitude,peak_index,peak_power,result_overflow,event_pulse);
                errors=errors+1;
            end else $display("PASS tone %0f Hz amp=%0d power=%0d",tone_frequency,amplitude,peak_power);
            // Independent direct DFT sum checks numeric scale/sign and guards
            // against a detector which selects the right index but wrong power.
            reference_power=(reference_real*reference_real+reference_imag*reference_imag)/(BANDS==8?33554432.0:131072.0);
            relative_error=(peak_power*1.0-reference_power)/reference_power;
            if(relative_error>0.03 || relative_error< -0.03) begin
                $display("FAIL direct DFT power reference=%0f DUT=%0d error=%0f",reference_power,peak_power,relative_error);
                errors=errors+1;
            end
            held_powers={power0,power1,power2,power3,power4,power5,power6,power7};
            repeat(10) begin
                @(negedge clk);
                if(result_valid || event_pulse || {power0,power1,power2,power3,power4,power5,power6,power7} !== held_powers) errors=errors+1;
            end
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst=0;
        // Bus changes without valid must not advance the accepted sample count.
        sample_in=32767;
        repeat(20) @(negedge clk);
        if(sample_count!=0 || result_valid || !sample_ready) errors=errors+1;
        for(i=0;i<BANDS;i=i+1) tone_window(i,12000);
        // All four full-scale tones check recurrence width/sign propagation.
        for(i=0;i<BANDS;i=i+1) tone_window(i,32767);
        // A full signed-range square wave is a stronger state excitation than
        // a full-scale sine and covers the -32768 input boundary.
        for(n=0;n<1024;n=n+1) begin
            sample_value=($sin(2.0*3.141592653589793*(BANDS==8?187.5:261.63)*n/48000.0)>=0.0)?32767:-32768;
            send_sample(sample_value);
        end
        await_result;
        if(peak_index!=0 || result_overflow || !event_pulse) begin
            $display("FAIL full signed-range square excitation");errors=errors+1;
        end
        if(BANDS==8) begin
            // Full-range quarter-cycle square wave excites both quadratures
            // at 12 kHz and nearly fills the compact 24-bit power output.
            for(n=0;n<1024;n=n+1)send_sample((n%4<2)?32767:-32768);
            await_result;
            if(peak_index!=7 || power7!==32'h00FFFE00 || result_overflow) begin
                $display("FAIL 24-bit power boundary p7=%h",power7);errors=errors+1;
            end
            for(n=0;n<1024;n=n+1) begin
                sample_value=$rtoi(10000*$sin(2*3.141592653589793*375*n/48000)+
                    5000*$sin(2*3.141592653589793*9000*n/48000));
                send_sample(sample_value);
            end
            await_result;
            if(peak_index!=1 || power1<742187 || power1>820313 ||
                power6<175781 || power6>214844 || result_overflow) begin
                $display("FAIL two-tone independence p1=%0d p6=%0d",power1,power6);errors=errors+1;
            end
        end
        for(n=0;n<1024;n=n+1) send_sample(0);
        await_result;
        if(event_pulse || peak_power!=0 || {power0,power1,power2,power3,power4,power5,power6,power7}!=0 || result_overflow) errors=errors+1;
        // Invalid input during processing is explicitly reported and discarded.
        send_sample(-32768);
        @(negedge clk); sample_valid=1; sample_in=32767;
        @(negedge clk); sample_valid=0;
        while(!sample_ready) @(negedge clk);
        if(!sample_overrun || sample_count!=1) errors=errors+1;
        // Reset discards a partial window and sticky overrun/outputs.
        @(negedge clk); rst=1;
        @(negedge clk); rst=0;
        if(sample_count!=0 || sample_overrun || result_valid || peak_power!=0 || !sample_ready) errors=errors+1;
        if(errors==0) $display("ALL TESTS PASSED: %0d Goertzel tones, direct DFT, full-scale, two-tone, silence, handshake, pulse/hold, reset",BANDS);
        else $fatal(1,"%0d TESTS FAILED",errors);
        $finish;
    end
    initial begin #10000000; $fatal(1,"test timeout"); end
endmodule

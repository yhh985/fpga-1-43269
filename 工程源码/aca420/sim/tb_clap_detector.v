`timescale 1ns/1ps
module tb_clap_detector;
    reg clk=0, rst_n=0, valid=0;
    reg signed [15:0] sample=0;
    always #10 clk=~clk;
    wire clap,active,calibrated,clipped;
    wire [16:0] peak,noise,threshold;
    wire [15:0] count;
    aca_clap_detector #(.WINDOW_BITS(4),.CALIBRATION_FRAMES(80),
        .QUIET_FRAMES(8),.RELEASE_FRAMES(3),.MAX_ACTIVE_FRAMES(40),.COOLDOWN_FRAMES(50)) dut (
        .clk(clk),.rst_n(rst_n),.sample_valid(valid),.sample(sample),
        .clap(clap),.active(active),.calibrated(calibrated),.clipped(clipped),
        .frame_peak(peak),.noise_floor(noise),.threshold(threshold),.clap_count(count));
    integer pulses=0,i,j,k;
    reg last_clap=0;
    always @(posedge clk) begin
        #1;
        if(clap) begin
            if(last_clap) $fatal(1,"clap was not one clock");
            pulses=pulses+1;
        end
        last_clap=clap;
    end
    task feed;
        input integer value;
        begin
            @(negedge clk); sample=value;valid=1;
            @(negedge clk);valid=0;
            repeat(3) @(negedge clk);
        end
    endtask
    task quiet_frames;
        input integer n;
        input integer offset;
        integer a,b;
        begin for(a=0;a<n;a=a+1) for(b=0;b<16;b=b+1) feed(offset+(b%3-1)*15); end
    endtask
    task transient;
        input integer polarity;
        integer a,b;
        begin
            for(a=0;a<4;a=a+1)
                for(b=0;b<16;b=b+1) feed(polarity*((b&1)?-1:1)*(12000>>(a/2)));
        end
    endtask
    initial begin
        #1; rst_n=0; #100;rst_n=1;
        quiet_frames(120,8000); // DC bias + small ambient noise, no events.
        if(!calibrated || count!=0) $fatal(1,"calibration/DC rejection failed");
        // A sudden input DC step also needs filter settling, candidate timeout,
        // cooldown and a fresh quiet interval before the next genuine event.
        quiet_frames(200,0);
        if(count!=0) $fatal(1,"DC step triggered an event");
        transient(1);quiet_frames(30,0);
        if(count!=1 || pulses!=1) $fatal(1,"first transient count=%0d pulses=%0d",count,pulses);
        transient(-1);quiet_frames(20,0);
        if(count!=1) $fatal(1,"ringing/cooldown produced duplicate event");
        quiet_frames(100,0);transient(-1);quiet_frames(30,0);
        if(count!=2) $fatal(1,"negative transient not detected");
        quiet_frames(100,0);
        for(i=0;i<100;i=i+1) for(j=0;j<16;j=j+1) feed((j&1)?-12000:12000);
        quiet_frames(100,0);
        if(count!=2) $fatal(1,"sustained tone/speech triggered an event");
        feed(32767);quiet_frames(100,0);
        if(count!=2) $fatal(1,"single electrical spike triggered an event");
        for(k=0;k<8;k=k+1) begin
            transient((k&1)?1:-1);quiet_frames(120,0);
        end
        if(count!=10 || pulses!=10) $fatal(1,"repeated separated events missing: %0d",count);
        // Exercise an onset split across a frame boundary: first frame has
        // exactly one loud sample; the following frames contain the short sound.
        quiet_frames(100,0);
        while(dut.sample_index!=15) feed(0);
        feed(12000);transient(1);quiet_frames(100,0);
        if(count!=11 || pulses!=11) $fatal(1,"frame-boundary onset was missed");
        @(negedge clk);rst_n=0;#80;rst_n=1;
        quiet_frames(120,-11000);
        if(count!=0 || !calibrated) $fatal(1,"reset/recalibration failed");
        $display("PASS detector: DC/noise rejection, 11 transients including frame-boundary onset, cooldown, long tone, spike, reset");
        $finish;
    end
    initial begin #20000000; $fatal(1,"detector timeout"); end
endmodule

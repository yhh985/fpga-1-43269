`timescale 1ns/1ps
module tb_audio_band_overlay;
    parameter integer BANDS=4;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,vs=0,de=0,en=1,valid=0;
    reg [31:0] p0=0,p1=0,p2=0,p3=0;
    reg [31:0] p4=0,p5=0,p6=0,p7=0;
    wire [23:0] rgb;
    integer errors=0,x,y,index,h,offset,k,probe_index,bit_length,reference_height;
    reg [31:0] probe,shifted;
    reg [23:0] expected,color;
    audio_band_overlay #(.BAND_COUNT(BANDS),.FRAME_WIDTH(64),.FRAME_HEIGHT(32),.BOX_X(0),.BOX_Y(8),
        .BOX_WIDTH(64),.BAR_HEIGHT(16),.BAR_GAP(4),
        .POWER_BASE_BIT(BANDS==8?3:11),.NOISE_GATE(BANDS==8?16:4096)) dut(
        .I_video_clk(clk),.I_rst(rst),.I_vs(vs),.I_de(de),.I_rgb(24'h808080),
        .I_enable(en),.I_result_valid(valid),.I_peak_index({((BANDS==8)?3:2){1'b0}}),
        .I_power0(p0),.I_power1(p1),.I_power2(p2),.I_power3(p3),
        .I_power4(p4),.I_power5(p5),.I_power6(p6),.I_power7(p7),.O_rgb_out(rgb)
    );
    task boundary;
        begin
            @(negedge clk); vs=1;
            repeat(2) @(negedge clk);
            vs=0; @(posedge clk); #1;
        end
    endtask
    task draw;
        input integer mode;
        begin
            for(y=0;y<32;y=y+1) begin
                @(negedge clk); de=1;
                for(x=0;x<64;x=x+1) begin
                    @(posedge clk); #1;
                    expected=24'h808080;
                    if(mode!=2 && y>=8 && y<24) begin
                        expected=24'h404040;
                        if(mode==1) begin
                            index=x/(64/BANDS); offset=x%(64/BANDS);
                            case(index)
                                0: begin h=16;color=24'h40C8FF;end
                                1: begin h=12;color=24'h40FFE0;end
                                2: begin h=4;color=24'h70FF80;end
                                3: begin h=0;color=24'hE0FF60;end
                                4: begin h=8;color=24'hFFD060;end
                                5: begin h=16;color=24'hFF9060;end
                                6: begin h=0;color=24'hFF70C0;end
                                default: begin h=12;color=24'hB090FF;end
                            endcase
                            if(offset>=2 && offset<64/BANDS-2 && y>=24-h) begin
                                expected=(y==24-h && h!=0)?24'hFFFFFF:color;
                            end
                        end
                    end
                    if(rgb!==expected) begin
                        if(errors<5) $display("FAIL x=%0d y=%0d mode=%0d got=%h expected=%h",x,y,mode,rgb,expected);
                        errors=errors+1;
                    end
                end
                @(negedge clk); de=0;
                @(posedge clk); #1;
                if(rgb!==24'h808080) begin $display("FAIL blanking bypass");errors=errors+1;end
                @(posedge clk); #1;
            end
        end
    endtask
    initial begin
        // Independent integer-log reference, including powers of two and
        // gate/saturation boundaries, checks the compact height encoder.
        for(probe_index=0;probe_index<96;probe_index=probe_index+1)begin
            probe=(32'd1<<(probe_index/3))+(probe_index%3)-1;
            shifted=probe;bit_length=0;
            while(shifted!=0)begin shifted=shifted>>1;bit_length=bit_length+1;end
            reference_height=(bit_length-1-(BANDS==8?3:11))*4;
            if(probe==0 || probe<(BANDS==8?16:4096))reference_height=0;
            else if(reference_height<1)reference_height=1;
            else if(reference_height>16)reference_height=16;
            if(dut.power_height(probe)!==reference_height)$fatal(1,"power height mismatch p=%h",probe);
        end
        repeat(3) @(negedge clk);rst=0;
        // Non-valid power changes remain invisible.
        p0=32'h10000;p1=32'h4000;p2=32'h1000;
        p4=32'h2000;p5=32'h10000;p6=0;p7=32'h4000;
        if(BANDS==8)begin
            p0=p0>>8;p1=p1>>8;p2=p2>>8;p4=p4>>8;p5=p5>>8;p7=p7>>8;
        end
        boundary;draw(0);
        // Atomic commit at VS then all four independent bars are checked.
        @(negedge clk);valid=1;
        @(negedge clk);valid=0;
        boundary;draw(1);
        // A new result during active video cannot change the current frame.
        @(negedge clk);p0=0;p1=0;p2=0;p4=0;p5=0;p7=0;valid=1;
        @(negedge clk);valid=0;
        if(dut.active_h[0]!=16 || dut.peak_h[0]!=16)$fatal(1,"non-atomic envelope");
        boundary;
        if(dut.active_h[0]!=14 || dut.peak_h[0]!=16)$fatal(1,"smooth fall/peak hold");
        for(k=0;k<32;k=k+1)boundary;
        for(k=0;k<BANDS;k=k+1)
            if(dut.active_h[k]!=0 || dut.peak_h[k]!=0)$fatal(1,"silence did not clear envelopes");
        draw(0);
        // A result coincident with VS must commit the complete new snapshot.
        @(negedge clk);vs=1;repeat(2)@(negedge clk);
        vs=0;valid=1;p0=(BANDS==8)?32'h100:32'h10000;
        @(posedge clk);#1;
        if(dut.active_h[0]!=16 || dut.peak_h[0]!=16)$fatal(1,"same-edge VS/result commit");
        @(negedge clk);valid=0;
        en=0;boundary;draw(2);
        if(errors==0) $display("ALL TESTS PASSED: %0d measured bars, snapshot, smooth decay, peak hold/release, silence, one-cycle pixels, blanking/bypass",BANDS);
        else $fatal(1,"%0d TESTS FAILED",errors);
        $finish;
    end
endmodule

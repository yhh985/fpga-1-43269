`timescale 1ns/1ps
// Behavioral PLL model only: board PLL programming is checked by TD build.
module aca_audio_pll(input refclk,reset,output reg extlock=0,
    output clk0_out,clk1_out,output reg clk2_out=0);
    always #40.666667 clk2_out=~clk2_out;
    assign clk0_out=refclk; assign clk1_out=1'b0;
    integer lock_count=0;
    always @(posedge refclk or posedge reset) begin
        if(reset) begin extlock<=0;lock_count<=0;end
        else if(lock_count==20) extlock<=1;
        else lock_count<=lock_count+1;
    end
endmodule

module tb_audio_top;
    reg clk=0,reset_n=0,key_n=1,adc=0,key_mode_n=1;
    always #10 clk=~clk;
    tri1 sda;
    wire scl,bclk,lrck,dac,mclk,tx;
    wire [7:0] led;
    aca420_audio_top #(.INIT_STARTUP_CYCLES(50),.INIT_SETTLE_CYCLES(2000),
      .KEY_DEBOUNCE_CYCLES(10),.DETECTOR_CALIBRATION_FRAMES(20),
      .REPORT_PERIOD_CYCLES(50000)) dut (
      .clk(clk),.reset_n(reset_n),.key_monitor_n(key_n),.iic_0_sda(sda),
      .iic_0_scl(scl),.I2S_DI(adc),.I2S_BCLK(bclk),.I2S_RCLK(lrck),
      .I2S_DO(dac),.I2S_MCLK(mclk),.led(led),.uart_tx(tx),.key_slot_n(1'b1),.key_learn_n(1'b1),.key_demo_n(key_mode_n),.link_rx(1'b1),.link_tx());
    // External I2C slave acknowledges all bytes; register contents are
    // independently checked in tb_es8388_init.
    reg slave_low=0,transaction=0,ack_phase=0;
    integer bits=0,bytes=0,transactions=0;
    assign sda=slave_low ? 1'b0:1'bz;
    always @(negedge sda) if(reset_n && scl) begin
        transaction=1;bits=0;bytes=0;ack_phase=0;
    end
    always @(posedge scl) if(reset_n && transaction) begin
        if(ack_phase) begin ack_phase=0;bits=0;bytes=bytes+1;end
        else bits=bits+1;
    end
    always @(negedge scl) if(reset_n && transaction) begin
        if(bits==8 && !ack_phase) begin slave_low=1;ack_phase=1;end
        else slave_low=0;
    end
    always @(posedge sda) if(reset_n && scl && transaction) begin
        transaction=0;slave_low=0;
        if(bytes!=3) $fatal(1,"top I2C length");
        transactions=transactions+1;
    end
    // ADC is driven using only externally visible BCLK/LRCK.
    integer bit_number=-1,pair_number=0,mode=0;
    reg previous_lrck=1;
    reg [15:0] word=0;
    always @(negedge bclk or negedge reset_n) begin
        if(!reset_n) begin bit_number=-1;pair_number=0;previous_lrck=1;adc=0;end
        else begin
            if(lrck!=previous_lrck) begin bit_number=0;previous_lrck=lrck;end
            else bit_number=bit_number+1;
            if(!lrck && bit_number==0) begin
                if(mode==1) word=pair_number[0] ? -16'sd12000:16'sd12000;
                else if(mode==2) word=16'h7fff;
                else word=pair_number[0] ? -16'sd12:16'sd12;
            end
            if(bit_number>=1 && bit_number<=16) adc=lrck ? 1'b0:word[16-bit_number];
            else adc=0;
            if(lrck && bit_number==31) pair_number=pair_number+1;
        end
    end
    integer samples=0;
    always @(posedge clk) begin
        #1;
        if(reset_n && !dut.cfg_done && dut.pcm_valid) $fatal(1,"PCM before configuration");
        if(dut.pcm_valid) samples=samples+1;
        if(reset_n && !dut.monitor_enable && dac!==0) $fatal(1,"monitor not muted");
    end
    task pairs;
        input integer n;
        integer stop_at;
        begin stop_at=pair_number+n;wait(pair_number>=stop_at);end
    endtask
    task press;
        begin @(negedge clk);key_n=0;repeat(30) @(negedge clk);
          key_n=1;repeat(30) @(negedge clk);end
    endtask
    initial begin
        #1;reset_n=0;#200;reset_n=1;
        wait(led[1]);
        if(led[2] || transactions!=43) $fatal(1,"top codec init failed");
        wait(dut.calibrated);pairs(1600);
        if(!led[3] || samples<1500 || dut.clap_count!=0) $fatal(1,"top quiet sampling/calibration");
        $display("top before transient: state=%0d quiet=%0d noise=%0d threshold=%0d pcm=%0d",dut.u_detector.state,dut.u_detector.quiet,dut.noise,dut.threshold,dut.pcm_left);
        mode=1;pairs(256);
        $display("top after transient: state=%0d peak=%0d mean=%0d pcm=%0d",dut.u_detector.state,dut.peak,dut.u_detector.frame_mean,dut.pcm_left);
        mode=0;pairs(500);
        if(dut.clap_count!=1) $fatal(1,"top candidate count=%0d",dut.clap_count);
        press();repeat(100) begin @(posedge mclk);#1;
          if(dac!==0 || dut.monitor_enable) $fatal(1,"voice build must keep monitor muted");end
        press();
        key_mode_n=0;repeat(30)@(negedge clk);key_mode_n=1;repeat(30)@(negedge clk);
        if(!dut.voice_mode || dut.voice_running || dut.kws_event || !dut.link_status[15])
          $fatal(1,"mode key/request or missing-host recognition gate");
        key_mode_n=0;repeat(30)@(negedge clk);key_mode_n=1;repeat(30)@(negedge clk);
        if(dut.voice_mode || dut.voice_running)$fatal(1,"mode key exit");
        mode=2;pairs(150);mode=0;
        if(!led[5]) $fatal(1,"top clipping flag");
        @(negedge clk);reset_n=0;slave_low=0;transaction=0;
        #200;transactions=0;reset_n=1;
        wait(led[1]);wait(dut.calibrated);
        if(transactions!=43 || dut.clap_count!=0 || dut.monitor_enable) $fatal(1,"top restart");
        $display("PASS top: init gate, external ADC, calibration, transient diagnostics, forced DAC mute, clipping, restart");
        $finish;
    end
    initial begin #150000000;$fatal(1,"top timeout");end
endmodule

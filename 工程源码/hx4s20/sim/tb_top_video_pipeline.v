`timescale 1ns/1ps

// This test instantiates the actual application top. Only peripheral sources
// outside the video/audio processors are no-op stubs. It drives the image/clock
// seams, then observes actual top stage wires and the real AXIS converter.
module tb_top_video_pipeline;
    reg clk=0; always #20 clk=~clk;
    reg sim_rst=1;
    reg sim_lock=0;
    reg sw2=1;
    reg sw1=1,sw3=1,sw4=1;
    reg src_hs=0,src_vs=0,src_de=0,src_sof=0,src_eol=0;
    reg [23:0] src_rgb=0;
    reg pcm_valid=0;
    reg signed [23:0] pcm_left=0;
    reg signed [23:0] pcm_right=0;
    wire ddc_sda;
    top #(.SWITCH_DEBOUNCE_CYCLES(8)) dut(.link_rx(1'b1),.link_tx(),.clk(clk),.key1(1'b1),.key2(1'b1),.key3(1'b1),.key4(1'b1),
        .sw1(sw1),.sw2(sw2),.sw3(sw3),.sw4(sw4),.sd_miso(1'b1),.HDMI_DDC_SDA(ddc_sda));

    reg [23:0] rgb_history[0:10];
    reg hs_history[0:10],vs_history[0:10],de_history[0:10];
    reg sof_history[0:10],eol_history[0:10];
    integer errors=0,cycles=0,i,x,y,frame_id;
    integer checked_pixels=0,sof_count=0,eol_count=0;
    integer audio_results=0,audio_samples=0,audio_n;
    reg video_done=0,audio_done=0;
    reg checker_enable=1;
    reg queue_audio_request=0;
    reg [1:0] queue_buffer_index=0;
    integer transition_pulses=0;
    integer pcm_value;
    function [23:0] pixel_tag;
        input integer frame_number;
        input integer row;
        input integer column;
        reg [7:0] red,green,blue;
        begin
            red=(column+17*row+23*frame_number)&255;
            green=(3*column+row+67*frame_number)&255;
            blue=(column^row^(frame_number*83))&255;
            pixel_tag={red,green,blue};
        end
    endfunction
    task fail;
        input [8*160-1:0] description;
        begin
            if(errors<12) $display("FAIL cycle=%0d %0s",cycles,description);
            errors=errors+1;
        end
    endtask

    // Independent expected transactions: the queue models only the externally
    // stated ten-clock delay; every actual processor remains in the DUT.
    always @(posedge clk) begin
        if(sim_rst) begin
            cycles=0;
            for(i=0;i<11;i=i+1) begin
                rgb_history[i]=0;hs_history[i]=0;vs_history[i]=0;de_history[i]=0;
                sof_history[i]=0;eol_history[i]=0;
            end
        end else begin
            cycles=cycles+1;
            if(dut.trans_start) transition_pulses=transition_pulses+1;
            for(i=10;i>0;i=i-1) begin
                rgb_history[i]=rgb_history[i-1];hs_history[i]=hs_history[i-1];
                vs_history[i]=vs_history[i-1];de_history[i]=de_history[i-1];
                sof_history[i]=sof_history[i-1];eol_history[i]=eol_history[i-1];
            end
            rgb_history[0]=src_rgb;hs_history[0]=src_hs;vs_history[0]=src_vs;
            de_history[0]=src_de;sof_history[0]=src_sof;eol_history[0]=src_eol;
            if(pcm_valid) begin
                audio_samples=audio_samples+1;

            end
            #1;
            if(cycles>16 && checker_enable) begin
                if(dut.vout_data_mic !== rgb_history[9]) fail("ten-stage RGB bypass mismatch");
                if(dut.hs_pipe[9] !== hs_history[9] || dut.vs_pipe[9] !== vs_history[9]
                   || dut.de_pipe[9] !== de_history[9]) fail("ten-stage HS/VS/DE mismatch");
                if(dut.axis_s_data !== rgb_history[10] || dut.axis_s_valid !== de_history[10]) fail("actual AXIS data/valid mismatch");
                if(dut.axis_s_user !== sof_history[10] || dut.axis_s_last !== eol_history[10]) fail("actual SOF/EOL misaligned with pixel");
                if(dut.axis_s_valid) checked_pixels=checked_pixels+1;
                if(dut.axis_s_user) sof_count=sof_count+1;
                if(dut.axis_s_last) eol_count=eol_count+1;
            end

        end
    end

    task drive_blank;
        input integer count;
        integer b;
        begin
            for(b=0;b<count;b=b+1) begin
                @(negedge clk);src_de=0;src_sof=0;src_eol=0;
                src_rgb=pixel_tag(frame_id,1000+b,b);
            end
        end
    endtask

    task blank_frame;
        begin
            @(negedge clk);src_vs=1;src_de=0;
            repeat(4) @(negedge clk);
            src_vs=0;
            repeat(12) @(negedge clk);
        end
    endtask

    // A failed SD read must remain diagnosable before the first image exists.
    // Drive the real video path far enough to observe actual diagnostic glyphs.
    task check_diagnostic_raster;
        input expected_visible;
        integer row,column,diagnostic_pixels,diagnostic_glyphs;
        reg glyph_expected;
        begin
            diagnostic_pixels=0;diagnostic_glyphs=0;
            for(row=0;row<49;row=row+1) begin
                for(column=0;column<640;column=column+1) begin
                    @(negedge clk);src_de=1;
                    @(posedge clk);
                    glyph_expected=dut.u_osd_status_overlay.diagnostic_on;
                    if(dut.u_osd_status_overlay.in_diagnostic) diagnostic_pixels=diagnostic_pixels+1;
                    #1;
                    if(glyph_expected) begin
                        diagnostic_glyphs=diagnostic_glyphs+1;
                        if(dut.vout_data_status!==24'hff4040)
                            fail("SD diagnostic glyph did not reach final RGB stage");
                    end
                end
                @(negedge clk);src_de=0;
                repeat(12) @(negedge clk);
            end
            if(expected_visible && (diagnostic_pixels==0 || diagnostic_glyphs==0))
                fail("automatic fallback hid SD diagnostic pixels");
            if(!expected_visible && (diagnostic_pixels!=0 || diagnostic_glyphs!=0))
                fail("manual test mode exposed SD diagnostic pixels");
        end
    endtask

    task check_startup_diagnostics;
        begin
            sw4=0;
            force dut.display_valid=1'b0;
            force dut.sd_status_code=4'd5;
            force dut.sd_error=1'b1;
            force dut.sd_error_code=4'd6;
            force dut.sd_last_cmd=6'd17;
            force dut.sd_last_r1=8'h00;
            drive_blank(12);
            blank_frame;
            if(!dut.video_fallback || !dut.video_test_active || dut.test_mode ||
               dut.u_osd_status_overlay.test_frame || !dut.u_osd_status_overlay.osd_frame ||
               !dut.u_osd_status_overlay.error_frame || dut.u_osd_status_overlay.state_frame!==4'd5 ||
               dut.u_osd_status_overlay.error_code_frame!==4'd6 ||
               dut.u_osd_status_overlay.last_cmd_frame!==6'd17 ||
               dut.u_osd_status_overlay.last_r1_frame!==8'h00)
                fail("automatic fallback lost startup SD E6 C17 R00 diagnostics");
            check_diagnostic_raster(1'b1);
            @(negedge clk);sw3=0;
            repeat(20) @(negedge clk);
            blank_frame;
            if(!dut.test_mode || !dut.u_osd_status_overlay.test_frame ||
               dut.u_osd_status_overlay.error_frame ||
               dut.u_osd_status_overlay.error_code_frame!==4'd0 ||
               dut.u_osd_status_overlay.state_frame!==4'd7)
                fail("manual SW3 test did not suppress SD error state");
            check_diagnostic_raster(1'b0);
            @(negedge clk);sw3=1;
            repeat(20) @(negedge clk);
            blank_frame;
            if(dut.test_mode || dut.u_osd_status_overlay.test_frame ||
               !dut.u_osd_status_overlay.error_frame ||
               dut.u_osd_status_overlay.error_code_frame!==4'd6)
                fail("leaving manual test did not restore startup SD diagnostics");
            release dut.sd_status_code;release dut.sd_error;release dut.sd_error_code;
            release dut.sd_last_cmd;release dut.sd_last_r1;
            sw4=1;
            blank_frame;
            $display("PASS actual top startup automatic colorbars retain SD E6 C17 R00 frame diagnostics and red glyphs; manual SW3 suppresses them");
        end
    endtask

    // Drive the physical SW3 input and observe the actual debounce/frame latch.
    // Keep forced events/no-card conditions hostile to prove test RGB stays bright.
    task check_test_mode;
        integer k;
        reg [23:0] expected;
        reg saved_audio_toggle;
        begin
            checker_enable=0;
            @(negedge clk);src_de=1;src_vs=0;
            sw3=0;repeat(3) @(negedge clk);
            sw3=1;repeat(12) @(negedge clk);
            blank_frame;
            if(dut.test_mode || dut.test_mode_db) fail("short SW3 bounce changed source");
            src_de=1;sw3=0;repeat(20) @(negedge clk);
            if(!dut.test_mode_db || dut.test_mode) fail("SW3 did not debounce or changed during active frame");
            blank_frame;
            if(!dut.test_mode) fail("debounced SW3 not latched at frame boundary");
            force dut.audio_link_start=queue_audio_request;
            force dut.disp_buf_idx=queue_buffer_index;
            // Peripheral reader acknowledges the selected base while black.
            force dut.read_buffer_index_mem=dut.visible_buf_idx;
            force dut.display_valid=1'b0;
            saved_audio_toggle=dut.audio_next_toggle;
            for(k=0;k<2400;k=k+1) begin
                @(negedge clk);
                src_de=1;queue_audio_request=~queue_audio_request;
                if(k%41==0) queue_buffer_index=~queue_buffer_index;
                if(k%200==0) blank_frame;
                @(posedge clk);expected=dut.test_rgb;#1;
                if(dut.vout_data_fx!==expected) fail("test pattern brightness changed by transition");
                if(dut.trans_start || dut.trans_active || dut.transition_pending)
                    fail("test mode retained audio/buffer transition");
                if(dut.audio_next_toggle!==saved_audio_toggle)
                    fail("test mode emitted SD audio request");
                if(dut.u_osd_status_overlay.trans_frame || dut.u_osd_status_overlay.alpha_frame)
                    fail("test mode retained yellow-bar status");
            end
            // Restore the forced buffer seam while still in test mode. With
            // retained validity, restoring it after leaving test mode would
            // deliberately count as a new committed picture for the next test.
            @(negedge clk);queue_audio_request=0;queue_buffer_index=0;src_vs=0;src_de=1;sw3=1;
            repeat(20) @(negedge clk);
            if(!dut.test_mode || dut.test_mode_db) fail("leaving test mode changed source during active frame");
            blank_frame;
            if(dut.test_mode || dut.trans_start || dut.trans_active)
                fail("leaving test mode replayed old transition");
            release dut.display_valid;
            queue_buffer_index=0;repeat(12) @(negedge clk);
            blank_frame;
            $display("PASS actual top SW3 bounce rejection, frame-locked sources, 2400 test pixels immune to audio/buffer/no-card events");
        end
    endtask

    // Only a committed picture queues an effect; audio never blacks the same image.
    task check_transition_queue;
        integer f;
        reg [4:0] previous_alpha;
        begin
            checker_enable=0;
            force dut.audio_link_start=queue_audio_request;
            force dut.disp_buf_idx=queue_buffer_index;
            force dut.display_valid=1'b1;
            repeat(12) @(negedge clk);
            blank_frame;
            transition_pulses=0;
            @(negedge clk);src_de=1;src_vs=0;queue_audio_request=1;
            @(posedge clk);#1;
            if(dut.transition_pending || dut.trans_start || dut.trans_active)
                fail("audio event directly faded unchanged picture");
            @(negedge clk);queue_audio_request=0;queue_buffer_index=1;
            repeat(7) begin
                @(posedge clk);#1;
                if(dut.trans_start || dut.trans_active) fail("buffer request started before VS falling");
            end
            if(!dut.transition_pending) fail("committed buffer request was lost");
            @(negedge clk);queue_audio_request=1;
            @(negedge clk);queue_audio_request=0;src_vs=1;src_de=0;
            repeat(2) @(negedge clk);
            src_vs=0;
            #1;if(!dut.trans_start) fail("queued request not offered at VS falling");
            @(posedge clk);#1;
            if(dut.transition_pending || !dut.trans_active || transition_pulses!=1)
                fail("coalesced transition was not consumed exactly once");
            @(posedge clk);#1;
            if(dut.trans_start) fail("transition start lasted more than one clock");
            @(negedge clk);src_vs=1;
            repeat(2) @(negedge clk);src_vs=0;
            repeat(3) @(posedge clk);#1;
            if(transition_pulses!=1) fail("empty following frame repeated a queued request");
            previous_alpha=dut.trans_alpha;
            for(f=0;f<72;f=f+1) begin
                @(negedge clk);queue_audio_request=1;
                if(f==2) queue_buffer_index=0;
                if(f==5) queue_buffer_index=1;
                @(negedge clk);queue_audio_request=0;
                blank_frame;
                if(dut.trans_active && dut.trans_alpha<previous_alpha)
                    fail("active transition restarted and reduced brightness");
                previous_alpha=dut.trans_alpha;
            end
            if(dut.trans_active || transition_pulses!=1 || dut.transition_pending)
                fail("busy audio/buffer events replayed or prolonged transition");
            release dut.audio_link_start;release dut.disp_buf_idx;release dut.display_valid;
            release dut.read_buffer_index_mem;
            $display("PASS actual top only real picture changes fade, queued to VS once; audio/busy events cannot restart brightness");
        end
    endtask
    task drive_frame;
        input integer number;
        begin
            frame_id=number;
            @(negedge clk);src_vs=1;src_de=0;src_hs=1;src_sof=0;src_eol=0;
            drive_blank(6);
            @(negedge clk);src_vs=0;src_hs=0;
            drive_blank(20);
            for(y=0;y<480;y=y+1) begin
                for(x=0;x<640;x=x+1) begin
                    @(negedge clk);
                    src_de=1;src_hs=0;src_rgb=pixel_tag(number,y,x);
                    src_sof=(y==0 && x==0);src_eol=(x==639);
                end
                @(negedge clk);src_de=0;src_sof=0;src_eol=0;src_hs=1;
                drive_blank(4);
                @(negedge clk);src_hs=0;
                drive_blank(16);
            end
            drive_blank(20);
        end
    endtask

    initial begin
        force dut.video_clk=clk;
        force dut.sd_card_clk=clk;
        force dut.ext_mem_clk=clk;
        force dut.ext_mem_clk_sft=clk;
        force dut.audio_mclk=1'b0;
        force dut.rst_all=sim_rst;
        force dut.all_pll_locked=sim_lock;
        force dut.hs=src_hs;force dut.vs=src_vs;force dut.de=src_de;
        force dut.vout_data_raw=src_rgb;
        force dut.display_valid=1'b1;
        force dut.audio_valid=pcm_valid;
        force dut.audio_left_data=pcm_left;force dut.audio_right_data=pcm_right;
        repeat(5) @(negedge clk);
        // Control the PLL hardware seam, not the reset output. The memory POR
        // must finish on its own clocks even while the main-domain POR is high.
        sim_lock=1;
        repeat(219) @(negedge clk);
        if(dut.rst_mem!==0 || dut.rst_all!==1)
            fail("memory local POR depends on main-domain POR or failed to release");
        if(dut.rst_sd!==1) fail("SD local POR released before 320 + 3 clocks");
        repeat(103) @(negedge clk);
        if(dut.rst_sd!==1) fail("SD local POR released before its final clock");
        @(negedge clk);
        if(dut.rst_sd!==0 || dut.rst_all!==1)
            fail("SD local POR depends on main-domain POR or failed to release");
        sim_lock=0;#1;
        if(dut.rst_mem!==1) fail("real memory reset did not assert on PLL unlock");
        if(dut.rst_sd!==1) fail("real SD reset did not assert on PLL unlock");
        @(negedge clk);sim_lock=1;
        repeat(218) @(negedge clk);
        if(dut.rst_mem!==1) fail("real memory reset released before the local startup hold");
        @(negedge clk);
        if(dut.rst_mem!==0) fail("real memory reset did not repeat its local startup hold");
        repeat(103) @(negedge clk);
        if(dut.rst_sd!==1) fail("real SD reset did not repeat its local startup hold");
        @(negedge clk);
        if(dut.rst_sd!==0) fail("real SD reset failed to release after repeated unlock");
        $display("PASS actual top SD local reset: 320 hold + 3 destination clocks, asynchronous PLL unlock, repeated startup, independent of main POR");
        checker_enable=0;
        sim_rst=0;
        check_startup_diagnostics;
        // Model the raw-reader VS starting prefetch before the delayed pixel VS.
        // Completion occurs inside that 23-clock gap. The first visible source
        // still contains a prefetched stale pixel and must retain the colorbars.
        force dut.display_valid=1'b0;
        drive_blank(12);
        @(negedge clk);src_vs=1;src_de=0;
        repeat(4) @(negedge clk);
        force dut.video_read_req=1'b1;
        src_rgb=24'hDEADBE;
        repeat(5) @(negedge clk);
        force dut.video_read_req=1'b0;
        force dut.display_valid=1'b1;
        repeat(18) @(negedge clk);
        if(dut.display_valid_frame || !dut.video_fallback || !dut.video_test_active ||
           dut.vout_data!==dut.test_rgb)
            fail("first image completion changed source before VS");
        src_vs=0;
        @(posedge clk);#1;
        if(!dut.display_valid_sampled || dut.display_valid_frame || !dut.video_fallback ||
           dut.vout_data!==dut.test_rgb)
            fail("first delayed VS exposed data prefetched before image completion");
        @(negedge clk);src_de=1;
        repeat(16) begin
            @(posedge clk);#1;
            if(dut.display_valid_frame || !dut.video_fallback || dut.vout_data!==dut.test_rgb)
                fail("first guarded frame exposed stale prefetch pixel");
        end
        @(negedge clk);src_de=0;src_rgb=24'h123456;
        release dut.video_read_req;
        blank_frame;
        if(!dut.display_valid_frame || dut.vout_data!==24'h123456)
            fail("second delayed VS did not expose complete first image");
        force dut.display_valid=1'b0;
        blank_frame;
        if(!dut.display_valid_frame) fail("an already valid image was hidden after source health loss");
        force dut.display_valid=1'b1;
        $display("PASS actual top first-image raw-reader prefetch window retains colorbars through first delayed VS; second VS reveals image and validity is retained");
        drive_blank(30);
        checker_enable=1;
        // Default brightness, contrast, filter, both bar enables and OSD are
        // left on the top's actual reset/control path; only hardware seams force.
        if(dut.brightness_r!=16 || dut.contrast_r!=16 || dut.filter_sync1!=0
           || dut.spectrum_sync1!=0 || dut.trans_active) fail("top default processing controls are not neutral");
        drive_frame(0);
        // Change the real SW2 synchronizer path with the common bar enable off:
        // this traverses both mutually-selected visualization branches as bypass.
        @(negedge clk);sw2=0;
        drive_blank(30);
        if(!dut.band_mode_sync[1] || dut.spectrum_sync1) fail("real SW2 selection/spectrum-off control mismatch");
        drive_frame(1);
        video_done=1;
        while(!audio_done) drive_blank(1);
        drive_blank(50);
        if(checked_pixels!=614400 || sof_count!=2 || eol_count!=960) begin
            $display("FAIL frame totals pixels=%0d SOF=%0d EOL=%0d",checked_pixels,sof_count,eol_count);
            errors=errors+1;
        end
        if(audio_samples!=2048) begin
            $display("FAIL audio totals samples=%0d results=%0d",audio_samples,audio_results);
            errors=errors+1;
        end
        check_test_mode;
        check_transition_queue;
        if(errors==0) $display("ALL TESTS PASSED: actual top 10-stage RGB/HS/VS/DE, 614400 pixels, SOF/EOL, both bar modes off, 2048 PCM samples at 520-clock spacing, ACA spectrum tested separately");
        else $fatal(1,"%0d TOP INTEGRATION TESTS FAILED",errors);
        $finish;
    end
    initial begin
        wait(!sim_rst);
        repeat(40) @(negedge clk);
        for(audio_n=0;audio_n<2048;audio_n=audio_n+1) begin
            pcm_value=$rtoi(12000.0*$sin(2.0*3.141592653589793*375.0*audio_n/48000.0));
            @(negedge clk);pcm_left=pcm_value*256;pcm_right=pcm_value*256;pcm_valid=1;
            @(negedge clk);pcm_valid=0;pcm_left=0;pcm_right=0;
            repeat(518) @(negedge clk);
        end
        repeat(50) @(negedge clk);
        audio_done=1;
    end
    initial begin #60000000;$fatal(1,"actual top integration timeout");end
endmodule

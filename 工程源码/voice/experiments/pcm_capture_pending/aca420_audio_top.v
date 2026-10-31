`timescale 1ns/1ps
// ACA420 coprocessor: ES8388 PCM -> spectrum / rhythm -> reliable UART link.
module aca420_audio_top #(
    parameter integer KEY_DEBOUNCE_CYCLES=1000000,
    parameter integer INIT_STARTUP_CYCLES=500000,
    parameter integer INIT_SETTLE_CYCLES=25000000,
    parameter integer DETECTOR_CALIBRATION_FRAMES=200,
    parameter integer REPORT_PERIOD_CYCLES=5000000
)(
    input wire music_bclk,music_lrck,music_in,output wire music_out,
    input wire clk, input wire reset_n, input wire key_monitor_n,
    inout wire iic_0_sda, output wire iic_0_scl,
    input wire I2S_DI,
    output wire I2S_RCLK, I2S_BCLK, I2S_DO, I2S_MCLK,
    output wire [7:0] led,
    output wire uart_tx,
    input wire key_slot_n,key_learn_n,key_demo_n,link_rx,output wire link_tx
);
    wire locked, audio_mclk;
    wire link_online,host_voice_enable;
    reg voice_mode;reg [1:0] music_effect;

    reg [1:0] last_command;
    wire voice_running=voice_mode && link_online && host_voice_enable;
    wire kws_event,kws_fault,kws_result;
    wire [1:0] kws_command,kws_class;
    wire feature_valid,feature_done,frontend_fault;
    wire vad_ready,vad_speech,kws_window_ready,kws_quiet_ready,kws_utterance,kws_processing,kws_rejected;
    wire [7:0] kws_reject_flags;
    wire [15:0] kws_debug_sequence;
    wire [6:0] kws_debug_voiced,kws_debug_duration;
    wire [287:0] kws_debug_logits;
    reg [25:0] voice_reject_hold;
    reg voice_feedback_rejected;
    always @(posedge clk)begin
      if(rst_sys || !voice_running || kws_event)begin voice_reject_hold<=0;voice_feedback_rejected<=0;end
      else if(kws_rejected)begin voice_reject_hold<=37500000;voice_feedback_rejected<=1;end
      else if(kws_processing)begin voice_reject_hold<=7500000;voice_feedback_rejected<=0;end
      else if(voice_reject_hold!=0)voice_reject_hold<=voice_reject_hold-1'b1;
    end
    wire [3:0] feature_index;wire signed [7:0] feature_data;
    wire learning,event_valid,learned_pulse,rejected;
    wire [2:0] learned,progress;
    wire clap, active, calibrated, clipped;
    wire [16:0] peak, noise, threshold;
    wire [15:0] clap_count;
    aca_audio_pll u_pll (
        .refclk(clk),.reset(~reset_n),.extlock(locked),
        .clk0_out(),.clk1_out(),.clk2_out(audio_mclk)
    );
    assign I2S_MCLK=audio_mclk;
    wire async_rst=~reset_n | ~locked;
    wire rst_sys, rst_audio;
    wire [3:0] music_input_state;
    wire [1:0] music_clock_code;
    wire selected_music_bclk,selected_music_lrck,music_clocks_swapped,music_clock_changed;
    aca_music_clock_route u_music_clock_route(.clk(clk),.rst(rst_sys),
      .pin_bclk(music_bclk),.pin_lrck(music_lrck),.code(music_clock_code),
      .selected_bclk(selected_music_bclk),.selected_lrck(selected_music_lrck),
      .swapped(music_clocks_swapped),.changed(music_clock_changed));
    music_fx_return #(.CHECKSUM(1)) u_music_fx(.clk(clk),.rst(rst_sys|music_clock_changed),.serial_bclk(selected_music_bclk),
      .serial_lrck(selected_music_lrck),.serial_data(music_in),.mode(music_effect),.serial_return(music_out),
      .input_state(music_input_state));
    reset_release #(.HOLD_CYCLES(1024)) u_sys_reset (
        .I_clk(clk),.I_async_rst(async_rst),.O_rst(rst_sys)
    );
    reset_release #(.HOLD_CYCLES(256)) u_audio_reset (
        .I_clk(audio_mclk),.I_async_rst(async_rst),.O_rst(rst_audio)
    );
    wire cfg_done, cfg_error;
    wire [5:0] cfg_index;
    aca_es8388_init #(
        .STARTUP_CYCLES(INIT_STARTUP_CYCLES),.SETTLE_CYCLES(INIT_SETTLE_CYCLES)
    ) u_init (
        .clk(clk),.rst_n(~rst_sys),.scl(iic_0_scl),.sda(iic_0_sda),
        .done(cfg_done),.error(cfg_error),.reg_index(cfg_index)
    );
    (* async_reg="true", syn_preserve=1 *) reg [1:0] enable_sync;
    (* async_reg="true", syn_preserve=1 *) reg [1:0] monitor_sync;
    reg monitor_enable;
    always @(posedge audio_mclk or posedge rst_audio) begin
        if(rst_audio) begin enable_sync<=0; monitor_sync<=0; end
        else begin
            enable_sync<={enable_sync[0],cfg_done};
            monitor_sync<={monitor_sync[0],monitor_enable};
        end
    end
    wire signed [15:0] source_left, source_right;
    wire pair_toggle;
    aca_i2s_capture u_capture (
        .mclk(audio_mclk),.audio_rst_n(~rst_audio),.enable(enable_sync[1]),
        .adcdat(I2S_DI),.bclk(I2S_BCLK),.lrck(I2S_RCLK),
        .left_hold(source_left),.right_hold(source_right),.pair_toggle(pair_toggle)
    );
    // No ADC-to-DAC monitor in either operating mode.
    assign I2S_DO=1'b0; // Recognition input is never sent to headphones/speakers.
    wire pcm_valid;
    wire signed [15:0] pcm_left, pcm_right;
    aca_pcm_mailbox u_pcm (
        .clk(clk),.rst_n(~rst_sys),.source_toggle(pair_toggle),
        .source_left(source_left),.source_right(source_right),
        .valid(pcm_valid),.left(pcm_left),.right(pcm_right)
    );
    wire voice_pcm_valid;wire signed [15:0] voice_pcm;
    aca_kws_frontend #(.ADAPTIVE_VAD(1)) u_kws_frontend(.clk(clk),.rst(rst_sys|!voice_running),
      .sample_valid(pcm_valid),.sample(pcm_left),.feature_valid(feature_valid),
      .feature_index(feature_index),.feature_data(feature_data),.frame_done(feature_done),.fault(frontend_fault),
      .vad_ready(vad_ready),.vad_speech(vad_speech),.debug_pcm_valid(voice_pcm_valid),.debug_pcm(voice_pcm));
    aca_kws_engine #(.COOLDOWN_CYCLES(20000000)) u_kws(.clk(clk),.rst(rst_sys|!voice_running),
      .feature_valid(feature_valid),.feature_index(feature_index),.feature_data(feature_data),
      .frame_done(feature_done),.result_valid(kws_result),.result_class(kws_class),
      .event_valid(kws_event),.event_command(kws_command),.fault(kws_fault),
      .window_ready(kws_window_ready),.quiet_ready(kws_quiet_ready),
      .utterance_active(kws_utterance),.processing(kws_processing),.rejected_pulse(kws_rejected),
      .reject_flags(kws_reject_flags),.debug_sequence(kws_debug_sequence),
      .debug_voiced(kws_debug_voiced),.debug_duration(kws_debug_duration),.debug_logits(kws_debug_logits));
    wire [2:0] short_keys,long_keys;
    aca_keys #(.DEBOUNCE(KEY_DEBOUNCE_CYCLES)) u_keys(.clk(clk),.rst(rst_sys),
        .keys_n({key_demo_n,key_learn_n,key_slot_n}),.short_press(short_keys),.long_press(long_keys));
    reg [1:0] slot;reg demo_enable;
    always @(posedge clk)begin
        if(rst_sys)begin music_effect<=0;slot<=0;demo_enable<=0;voice_mode<=0;last_command<=0;end
        else begin
            if(short_keys[0] && !learning)slot<=slot==2?0:slot+1'b1;
            if(short_keys[2])voice_mode<=~voice_mode;
            if(long_keys[1]&&!voice_mode)music_effect<=music_effect+1'b1;
            if(!voice_running)last_command<=0;
            else if(kws_event)last_command<=kws_command;
        end
    end
    wire demo_valid,demo_tap;wire signed [15:0] demo_sample;
    aca_demo u_demo(.clk(clk),.rst(rst_sys),.enable(demo_enable),.slot(slot),
        .sample_valid(demo_valid),.sample(demo_sample),.tap(demo_tap));
    reg previous_demo;
    always @(posedge clk)if(rst_sys)previous_demo<=0;else previous_demo<=demo_enable;
    wire input_changed=previous_demo!=demo_enable;
    wire analysis_reset=rst_sys|input_changed;
    wire analysis_valid=demo_enable?demo_valid:pcm_valid;
    wire signed [15:0] analysis_sample=demo_enable?demo_sample:pcm_left;
    wire rhythm_tap=demo_enable?demo_tap:clap;
    wire [1:0] event_command;wire [7:0] confidence;
    aca_rhythm u_rhythm(.clk(clk),.rst(rst_sys),.tap(rhythm_tap),
        .learn(1'b0),.clear(1'b0),.slot(slot),.learning(learning),
        .learned(learned),.progress(progress),.event_valid(event_valid),
        .event_command(event_command),.confidence(confidence),.rejected(rejected),.learned_pulse(learned_pulse));
    wire [63:0] mic_bars;wire [127:0] mic_wave;
    wire analysis_overrun,analysis_overflow;
    aca_analysis u_analysis(.clk(clk),.rst(analysis_reset),.sample_valid(analysis_valid),
        .sample(analysis_sample),.bars(mic_bars),.waveform(mic_wave),
        .overrun(analysis_overrun),.overflow(analysis_overflow));
    wire event_failed,queue_overflow;wire [15:0] link_crc_errors;
    // 32-byte payload: flags, selection+progress, learned, confidence,
    // bars[8], waveform[16], peak16, noise16. Snapshot at packet admission.
    wire [7:0] link_flags={analysis_overrun|analysis_overflow|frontend_fault|kws_fault,event_failed|queue_overflow,
        clipped,calibrated,cfg_error,cfg_done,learning,demo_enable};
    // Reuse inactive rhythm progress/slot fields only in voice mode. Marker
    // slot=3 distinguishes these diagnostics from older ACA status packets.
    wire [2:0] voice_stage=(cfg_error || frontend_fault || kws_fault)?3'd6:
      (!cfg_done || sample_alive==0)?3'd5:
      (!vad_ready || !kws_window_ready)?3'd1:
      kws_processing?3'd3:(vad_speech || kws_utterance)?3'd2:
      voice_reject_hold!=0?(voice_feedback_rejected?3'd4:3'd3):!kws_quiet_ready?3'd7:3'd0;
    wire [255:0] link_status={noise[15:0],peak[15:0],mic_wave,mic_bars,
        {music_input_state,(voice_mode?kws_class:{1'b0,music_clocks_swapped}),last_command},{1'b1,music_clock_code,music_effect,learned},{voice_mode,voice_running,1'b1,(voice_mode?voice_stage:progress),(voice_mode?2'b11:slot)},link_flags};
    link_sensor u_link(.clk(clk),.rst(rst_sys),.rx(link_rx),.tx(link_tx),.status(link_status),
        .event_valid((kws_event && voice_running)||(!voice_mode && (short_keys[0]||short_keys[1]||long_keys[1]))),
        .event_command(voice_mode ? {6'd0,kws_command} : long_keys[1] ? 8'd6 : short_keys[1] ? 8'd5 : 8'd4),.online(link_online),.host_voice_enable(host_voice_enable),
        .event_failed(event_failed),.queue_overflow(queue_overflow),.crc_errors(link_crc_errors));
    aca_clap_detector #(.CALIBRATION_FRAMES(DETECTOR_CALIBRATION_FRAMES)) u_detector (
        .clk(clk),.rst_n(~analysis_reset),.sample_valid(analysis_valid),.sample(analysis_sample),
        .clap(clap),.active(active),.calibrated(calibrated),.clipped(clipped),
        .frame_peak(peak),.noise_floor(noise),.threshold(threshold),.clap_count(clap_count)
    );
    (* async_reg="true", syn_preserve=1 *) reg [1:0] key_sync;
    reg key_stable;
    reg [19:0] key_count;
    reg [24:0] heartbeat;
    reg [23:0] clap_hold, sample_alive;
    reg [15:0] sample_count;
    reg [16:0] report_peak;
    reg clip_hold;
    reg [22:0] report_timer;
    always @(posedge clk or posedge rst_sys) begin
        if(rst_sys) begin
            key_sync<=2'b11; key_stable<=1; key_count<=0; monitor_enable<=0;
            heartbeat<=0; clap_hold<=0; sample_alive<=0; sample_count<=0;
            report_peak<=0; report_timer<=0; clip_hold<=0;
        end else begin
            key_sync<={key_sync[0],key_monitor_n};
            if(key_sync[1]==key_stable) key_count<=0;
            else if(key_count>=KEY_DEBOUNCE_CYCLES-1) begin
                key_count<=0; key_stable<=key_sync[1];
                monitor_enable<=0;
            end else key_count<=key_count+1'b1;
            if(heartbeat==24999999) heartbeat<=0;
            else heartbeat<=heartbeat+1'b1;
            if(kws_event) clap_hold<=10000000;
            else if(clap_hold!=0) clap_hold<=clap_hold-1'b1;
            if(pcm_valid) begin sample_count<=sample_count+1'b1; sample_alive<=5000000; end
            else if(sample_alive!=0) sample_alive<=sample_alive-1'b1;
            if(report_timer>=REPORT_PERIOD_CYCLES-1) begin
                report_timer<=0; report_peak<=peak; clip_hold<=clipped;
            end else begin
                report_timer<=report_timer+1'b1;
                if(peak>report_peak) report_peak<=peak;
                if(clipped) clip_hold<=1;
            end
        end
    end
    assign led[0]=heartbeat<12500000;
    assign led[1]=cfg_done;
    assign led[2]=cfg_error;
    assign led[3]=sample_alive!=0;
    assign led[4]=clap_hold!=0 && voice_running;
    assign led[5]=clip_hold;
    assign led[6]=voice_mode && (voice_running || heartbeat<12500000);
    assign led[7]=link_online;
    wire [7:0] flags={monitor_enable,calibrated,active,clip_hold,
        sample_alive!=0,locked,cfg_error,cfg_done};
    wire legacy_report_tx,feature_report_tx;
    assign uart_tx=voice_running?feature_report_tx:legacy_report_tx;
    aca_pcm_feature_report u_feature_report(.clk(clk),.rst_n(~rst_sys && voice_running),
      .pcm_valid(voice_pcm_valid),.pcm(voice_pcm),
      .feature_valid(feature_valid),.feature_index(feature_index),.feature_data(feature_data),.frame_done(feature_done),
      .flags(flags),.reject_flags(kws_reject_flags),.debug_sequence(kws_debug_sequence),
      .debug_voiced(kws_debug_voiced),.debug_duration(kws_debug_duration),.debug_logits(kws_debug_logits),
      .engine_state({4'd0,kws_processing,kws_utterance,kws_quiet_ready,kws_window_ready}),
      .peak(peak[15:0]),.noise(noise[15:0]),.sample_count(sample_count),.tx(feature_report_tx));
    aca_uart_report #(.PERIOD_CYCLES(REPORT_PERIOD_CYCLES)) u_report (
        .clk(clk),.rst_n(~rst_sys),.event_pending(rhythm_tap),.flags(flags),
        .clap_count(clap_count),.peak(report_peak>65535 ? 16'hffff:report_peak[15:0]),
        .noise(noise[15:0]),.threshold(threshold[15:0]),.sample_count(sample_count),
        .tx(legacy_report_tx)
    );
endmodule

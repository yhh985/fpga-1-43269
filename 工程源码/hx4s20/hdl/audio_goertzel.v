`timescale 1ns/1ps

// Four selected frequencies, not a full FFT spectrum. Default coefficients are
// 2*cos(2*pi*f/48000) in signed Q16 for f=261.63/329.63/392/523.25 Hz.
// A rectangular 1024-accepted-sample window is 21.33 ms at 48 kHz. Coefficient
// quantization shifts the centers slightly; there is no automatic Fs tracking.
//
// One shared (DATA_WIDTH+16)-bit signed multiplier computes all recurrences and
// powers. Default signed 16-bit PCM uses 31-bit recurrence states, enough for
// the worst bounded 1024-sample input at the lowest default frequency. Saturation
// sets result_overflow if a changed configuration/input exceeds that range.
// For 24-bit PCM connect the most significant 16 bits, preserving its sign.
//
// Accept a sample only when sample_valid && sample_ready. Ready goes low for
// eight clocks after a normal acceptance, and 29 clocks after the last sample.
// A sample presented while busy sets sticky sample_overrun and is discarded.
// Four output powers/peak fields update together and hold until the next result;
// result_valid and event_pulse last one clock. Power is magnitude squared >>17
// by default, saturated to unsigned 32 bits. Recurrence overflow and output
// power saturation are distinct: result_overflow reports recurrence clipping.
// Event threshold is in these normalized power units, not PCM or dB units.
module audio_goertzel #(
    parameter integer BAND_COUNT = 4,
    parameter integer INDEX_WIDTH = (BAND_COUNT == 8) ? 3 : 2,
    parameter integer DATA_WIDTH = 16,
    parameter integer WINDOW_LEN = 1024,
    parameter integer COEFF_FRAC = 16,
    parameter integer COEFF0 = 130995,
    parameter integer COEFF1 = 130950,
    parameter integer COEFF2 = 130899,
    parameter integer COEFF3 = 130765,
    parameter integer COEFF4 = 121095,
    parameter integer COEFF5 = 92682,
    parameter integer COEFF6 = 50159,
    parameter integer COEFF7 = 0,
    parameter integer FREQUENCY0 = 262,
    parameter integer FREQUENCY1 = 330,
    parameter integer FREQUENCY2 = 392,
    parameter integer FREQUENCY3 = 523,
    parameter integer FREQUENCY4 = 3000,
    parameter integer FREQUENCY5 = 6000,
    parameter integer FREQUENCY6 = 9000,
    parameter integer FREQUENCY7 = 12000,
    parameter integer POWER_SHIFT = 17,
    parameter integer POWER_WIDTH = 32,
    parameter [31:0] EVENT_THRESHOLD = 32'd4096
)(
    input wire clk,
    input wire rst,
    input wire sample_valid,
    input wire signed [DATA_WIDTH-1:0] sample_in,
    output wire sample_ready,
    output reg sample_overrun,
    output reg result_valid,
    output reg result_overflow,
    output reg event_pulse,
    output reg [INDEX_WIDTH-1:0] peak_index,
    output reg [15:0] peak_frequency,
    output reg [31:0] peak_power,
    output reg [31:0] power0,
    output reg [31:0] power1,
    output reg [31:0] power2,
    output reg [31:0] power3,
    output reg [31:0] power4,
    output reg [31:0] power5,
    output reg [31:0] power6,
    output reg [31:0] power7,
    output wire [15:0] sample_count
);
    localparam integer COUNT_WIDTH=(WINDOW_LEN<2)?1:$clog2(WINDOW_LEN);
    reg [COUNT_WIDTH-1:0] accepted_count;
    assign sample_count=accepted_count;
    localparam integer STATE_WIDTH = DATA_WIDTH + 15;
    localparam integer MULT_WIDTH = STATE_WIDTH + 1;
    localparam integer PROD_WIDTH = 2 * MULT_WIDTH;
    localparam [3:0] IDLE=0, FEEDBACK_MUL=1, FEEDBACK_SAVE=2,
        POWER_MUL=3, POWER_SQ1=4, POWER_SQ2=5, POWER_COEFF=6,
        POWER_SAVE=7, COMMIT=8;
    localparam signed [PROD_WIDTH-1:0] STATE_MAX =
        {{(PROD_WIDTH-STATE_WIDTH){1'b0}}, 1'b0, {(STATE_WIDTH-1){1'b1}}};
    localparam signed [PROD_WIDTH-1:0] STATE_MIN =
        {{(PROD_WIDTH-STATE_WIDTH){1'b1}}, 1'b1, {(STATE_WIDTH-1){1'b0}}};

    reg [3:0] state;
    reg [INDEX_WIDTH-1:0] band;
    reg signed [STATE_WIDTH-1:0] s1 [0:BAND_COUNT-1];
    reg signed [STATE_WIDTH-1:0] s2 [0:BAND_COUNT-1];
    reg signed [STATE_WIDTH-1:0] accepted_sample;
    reg signed [MULT_WIDTH-1:0] mul_a, mul_b;
    wire signed [PROD_WIDTH-1:0] mul_product = mul_a * mul_b;
    reg signed [PROD_WIDTH-1:0] square1, square2;
    reg [POWER_WIDTH-1:0] working_power [0:BAND_COUNT-1];
    reg [POWER_WIDTH-1:0] working_peak;
    reg [INDEX_WIDTH-1:0] working_index;
    reg window_overflow;
    integer ri;

    function signed [MULT_WIDTH-1:0] coefficient;
        input [INDEX_WIDTH-1:0] index;
        begin
            case (index)
                0: coefficient = COEFF0;
                1: coefficient = COEFF1;
                2: coefficient = COEFF2;
                3: coefficient = COEFF3;
                4: coefficient = COEFF4;
                5: coefficient = COEFF5;
                6: coefficient = COEFF6;
                default: coefficient = COEFF7;
            endcase
        end
    endfunction
    function [15:0] frequency;
        input [INDEX_WIDTH-1:0] index;
        begin
            case (index)
                0: frequency = FREQUENCY0;
                1: frequency = FREQUENCY1;
                2: frequency = FREQUENCY2;
                3: frequency = FREQUENCY3;
                4: frequency = FREQUENCY4;
                5: frequency = FREQUENCY5;
                6: frequency = FREQUENCY6;
                default: frequency = FREQUENCY7;
            endcase
        end
    endfunction

    wire signed [PROD_WIDTH-1:0] accepted_sample_ext =
        {{(PROD_WIDTH-STATE_WIDTH){accepted_sample[STATE_WIDTH-1]}}, accepted_sample};
    wire signed [PROD_WIDTH-1:0] previous_state_ext =
        {{(PROD_WIDTH-STATE_WIDTH){s2[band][STATE_WIDTH-1]}}, s2[band]};
    wire signed [PROD_WIDTH-1:0] recurrence = accepted_sample_ext
        + (mul_product >>> COEFF_FRAC) - previous_state_ext;
    wire recurrence_overflow = (recurrence > STATE_MAX) || (recurrence < STATE_MIN);
    wire signed [STATE_WIDTH-1:0] limited_recurrence = (recurrence > STATE_MAX)
        ? STATE_MAX[STATE_WIDTH-1:0] : (recurrence < STATE_MIN)
        ? STATE_MIN[STATE_WIDTH-1:0] : recurrence[STATE_WIDTH-1:0];

    // P=s1^2+s2^2-(Q16(coeff*s1))*s2. The Q16 truncation before the
    // final product saves a wider multiplier; tiny negative powers become zero.
    wire signed [PROD_WIDTH:0] raw_power =
        {square1[PROD_WIDTH-1], square1} + {square2[PROD_WIDTH-1], square2}
        - {mul_product[PROD_WIDTH-1], mul_product};
    wire signed [PROD_WIDTH:0] scaled_power = raw_power >>> POWER_SHIFT;
    localparam [PROD_WIDTH:0] POWER_MAX = {{(PROD_WIDTH+1-POWER_WIDTH){1'b0}},
        {POWER_WIDTH{1'b1}}};
    wire [POWER_WIDTH-1:0] normalized_power = (raw_power < 0) ? {POWER_WIDTH{1'b0}}
        : (scaled_power > POWER_MAX) ? {POWER_WIDTH{1'b1}} : scaled_power[POWER_WIDTH-1:0];
    assign sample_ready = (state == IDLE);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            band <= 2'd0;
            accepted_sample <= 0;
            mul_a <= 0; mul_b <= 0;
            square1 <= 0; square2 <= 0;
            accepted_count <= 0;
            sample_overrun <= 1'b0;
            window_overflow <= 1'b0;
            result_valid <= 1'b0;
            result_overflow <= 1'b0;
            event_pulse <= 1'b0;
            peak_index <= 0; peak_frequency <= 0; peak_power <= 0;
            power0 <= 0; power1 <= 0; power2 <= 0; power3 <= 0;
            power4 <= 0; power5 <= 0; power6 <= 0; power7 <= 0;
            working_peak <= 0; working_index <= 0;
            for (ri=0; ri<BAND_COUNT; ri=ri+1) begin
                s1[ri] <= 0; s2[ri] <= 0; working_power[ri] <= 0;
            end
        end else begin
            result_valid <= 1'b0;
            event_pulse <= 1'b0;
            if (sample_valid && !sample_ready) sample_overrun <= 1'b1;
            case (state)
                IDLE: if (sample_valid) begin
                    accepted_sample <= {{(STATE_WIDTH-DATA_WIDTH){sample_in[DATA_WIDTH-1]}}, sample_in};
                    band <= 0;
                    state <= FEEDBACK_MUL;
                end
                FEEDBACK_MUL: begin
                    mul_a <= {s1[band][STATE_WIDTH-1], s1[band]};
                    mul_b <= coefficient(band);
                    state <= FEEDBACK_SAVE;
                end
                FEEDBACK_SAVE: begin
                    s2[band] <= s1[band];
                    s1[band] <= limited_recurrence;
                    if (recurrence_overflow) window_overflow <= 1'b1;
                    if (band != BAND_COUNT-1) begin
                        band <= band + 1'b1;
                        state <= FEEDBACK_MUL;
                    end else if (sample_count == WINDOW_LEN-1) begin
                        band <= 0;
                        working_peak <= 0;
                        working_index <= 0;
                        state <= POWER_MUL;
                    end else begin
                        accepted_count <= accepted_count + 1'b1;
                        state <= IDLE;
                    end
                end
                POWER_MUL: begin
                    mul_a <= {s1[band][STATE_WIDTH-1], s1[band]};
                    mul_b <= {s1[band][STATE_WIDTH-1], s1[band]};
                    state <= POWER_SQ1;
                end
                POWER_SQ1: begin
                    square1 <= mul_product;
                    mul_a <= {s2[band][STATE_WIDTH-1], s2[band]};
                    mul_b <= {s2[band][STATE_WIDTH-1], s2[band]};
                    state <= POWER_SQ2;
                end
                POWER_SQ2: begin
                    square2 <= mul_product;
                    mul_a <= {s1[band][STATE_WIDTH-1], s1[band]};
                    mul_b <= coefficient(band);
                    state <= POWER_COEFF;
                end
                POWER_COEFF: begin
                    mul_a <= mul_product >>> COEFF_FRAC;
                    mul_b <= {s2[band][STATE_WIDTH-1], s2[band]};
                    state <= POWER_SAVE;
                end
                POWER_SAVE: begin
                    working_power[band] <= normalized_power;
                    if (band == 0 || normalized_power > working_peak) begin
                        working_peak <= normalized_power;
                        working_index <= band;
                    end
                    s1[band] <= 0; s2[band] <= 0;
                    if (band == BAND_COUNT-1) state <= COMMIT;
                    else begin band <= band + 1'b1; state <= POWER_MUL; end
                end
                COMMIT: begin
                    power0 <= working_power[0]; power1 <= working_power[1];
                    power2 <= working_power[2]; power3 <= working_power[3];
                    if (BAND_COUNT == 8) begin
                        power4 <= working_power[4]; power5 <= working_power[5];
                        power6 <= working_power[6]; power7 <= working_power[7];
                    end
                    peak_index <= working_index;
                    peak_frequency <= frequency(working_index);
                    peak_power <= working_peak;
                    result_overflow <= window_overflow;
                    result_valid <= 1'b1;
                    event_pulse <= (working_peak != 0) && (working_peak >= EVENT_THRESHOLD);
                    window_overflow <= 1'b0;
                    accepted_count <= 0;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule

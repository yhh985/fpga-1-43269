
// ============================================================
// 模块名：hdmi_audio_tone_i2s_64fs
// 功能：I2S 64fs 音频发送器 + DDS 正弦波音阶发生器
//   - do/re/mi/fa/so/la/si/do 八度音阶循环，每个音持续0.5秒
//   - 256点正弦ROM查表，相位累加器(NCO)生成正弦波
//   - 音色从方波改为柔和正弦波
// 时钟：I_mclk = 12.288MHz (256fs × 48kHz)
// ============================================================
module hdmi_audio_tone_i2s_64fs #(
    parameter [31:0] PHASE_INC = 32'd39370534,
    parameter signed [23:0] AMP = 24'sd2000000,
    parameter integer NOTE_HOLD_FRAMES = 24000
)(
    input  wire I_mclk,
    input  wire I_rst,
    output reg  O_i2s_BCLK,
    output reg  O_i2s_LRCK,
    output reg  O_i2s_DOUT
);

// do/re/mi/fa/so/la/si/do (C4~C5)，相位增量按48kHz计算
function [31:0] note_inc_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: note_inc_lut = 32'd23409862;
            3'd1: note_inc_lut = 32'd26276681;
            3'd2: note_inc_lut = 32'd29494578;
            3'd3: note_inc_lut = 32'd31248410;
            3'd4: note_inc_lut = 32'd35075155;
            3'd5: note_inc_lut = 32'd39370534;
            3'd6: note_inc_lut = 32'd44191930;
            default: note_inc_lut = 32'd46819716;
        endcase
    end
endfunction

reg  [5:0]  S_bit_cnt;
reg  [63:0] S_shift_reg;
reg  [31:0] S_phase_acc;       // 32位相位累加器
reg signed [23:0] S_sample_word;
reg signed [23:0] S_sample_next;
reg  [2:0]  S_note_idx;
reg [15:0]  S_note_frame_cnt;

wire [31:0] W_note_inc = note_inc_lut(S_note_idx);

// ============================================================
// 256点正弦ROM（8位有符号补码，-127~+127）
// 用相位累加器高8位(S_phase_acc[31:24])寻址
// ============================================================
reg signed [7:0] sin_val;
always @(*) begin
    case (S_phase_acc[31:24])
        8'd0: sin_val = 8'sh00;  8'd1: sin_val = 8'sh03;  8'd2: sin_val = 8'sh06;  8'd3: sin_val = 8'sh09;
        8'd4: sin_val = 8'sh0C;  8'd5: sin_val = 8'sh10;  8'd6: sin_val = 8'sh13;  8'd7: sin_val = 8'sh16;
        8'd8: sin_val = 8'sh19;  8'd9: sin_val = 8'sh1C;  8'd10: sin_val = 8'sh1F;  8'd11: sin_val = 8'sh22;
        8'd12: sin_val = 8'sh25;  8'd13: sin_val = 8'sh28;  8'd14: sin_val = 8'sh2B;  8'd15: sin_val = 8'sh2E;
        8'd16: sin_val = 8'sh31;  8'd17: sin_val = 8'sh33;  8'd18: sin_val = 8'sh36;  8'd19: sin_val = 8'sh39;
        8'd20: sin_val = 8'sh3C;  8'd21: sin_val = 8'sh3F;  8'd22: sin_val = 8'sh41;  8'd23: sin_val = 8'sh44;
        8'd24: sin_val = 8'sh47;  8'd25: sin_val = 8'sh49;  8'd26: sin_val = 8'sh4C;  8'd27: sin_val = 8'sh4E;
        8'd28: sin_val = 8'sh51;  8'd29: sin_val = 8'sh53;  8'd30: sin_val = 8'sh55;  8'd31: sin_val = 8'sh58;
        8'd32: sin_val = 8'sh5A;  8'd33: sin_val = 8'sh5C;  8'd34: sin_val = 8'sh5E;  8'd35: sin_val = 8'sh60;
        8'd36: sin_val = 8'sh62;  8'd37: sin_val = 8'sh64;  8'd38: sin_val = 8'sh66;  8'd39: sin_val = 8'sh68;
        8'd40: sin_val = 8'sh6A;  8'd41: sin_val = 8'sh6B;  8'd42: sin_val = 8'sh6D;  8'd43: sin_val = 8'sh6F;
        8'd44: sin_val = 8'sh70;  8'd45: sin_val = 8'sh71;  8'd46: sin_val = 8'sh73;  8'd47: sin_val = 8'sh74;
        8'd48: sin_val = 8'sh75;  8'd49: sin_val = 8'sh76;  8'd50: sin_val = 8'sh78;  8'd51: sin_val = 8'sh79;
        8'd52: sin_val = 8'sh7A;  8'd53: sin_val = 8'sh7A;  8'd54: sin_val = 8'sh7B;  8'd55: sin_val = 8'sh7C;
        8'd56: sin_val = 8'sh7D;  8'd57: sin_val = 8'sh7D;  8'd58: sin_val = 8'sh7E;  8'd59: sin_val = 8'sh7E;
        8'd60: sin_val = 8'sh7E;  8'd61: sin_val = 8'sh7F;  8'd62: sin_val = 8'sh7F;  8'd63: sin_val = 8'sh7F;
        8'd64: sin_val = 8'sh7F;  8'd65: sin_val = 8'sh7F;  8'd66: sin_val = 8'sh7F;  8'd67: sin_val = 8'sh7F;
        8'd68: sin_val = 8'sh7E;  8'd69: sin_val = 8'sh7E;  8'd70: sin_val = 8'sh7E;  8'd71: sin_val = 8'sh7D;
        8'd72: sin_val = 8'sh7D;  8'd73: sin_val = 8'sh7C;  8'd74: sin_val = 8'sh7B;  8'd75: sin_val = 8'sh7A;
        8'd76: sin_val = 8'sh7A;  8'd77: sin_val = 8'sh79;  8'd78: sin_val = 8'sh78;  8'd79: sin_val = 8'sh76;
        8'd80: sin_val = 8'sh75;  8'd81: sin_val = 8'sh74;  8'd82: sin_val = 8'sh73;  8'd83: sin_val = 8'sh71;
        8'd84: sin_val = 8'sh70;  8'd85: sin_val = 8'sh6F;  8'd86: sin_val = 8'sh6D;  8'd87: sin_val = 8'sh6B;
        8'd88: sin_val = 8'sh6A;  8'd89: sin_val = 8'sh68;  8'd90: sin_val = 8'sh66;  8'd91: sin_val = 8'sh64;
        8'd92: sin_val = 8'sh62;  8'd93: sin_val = 8'sh60;  8'd94: sin_val = 8'sh5E;  8'd95: sin_val = 8'sh5C;
        8'd96: sin_val = 8'sh5A;  8'd97: sin_val = 8'sh58;  8'd98: sin_val = 8'sh55;  8'd99: sin_val = 8'sh53;
        8'd100: sin_val = 8'sh51;  8'd101: sin_val = 8'sh4E;  8'd102: sin_val = 8'sh4C;  8'd103: sin_val = 8'sh49;
        8'd104: sin_val = 8'sh47;  8'd105: sin_val = 8'sh44;  8'd106: sin_val = 8'sh41;  8'd107: sin_val = 8'sh3F;
        8'd108: sin_val = 8'sh3C;  8'd109: sin_val = 8'sh39;  8'd110: sin_val = 8'sh36;  8'd111: sin_val = 8'sh33;
        8'd112: sin_val = 8'sh31;  8'd113: sin_val = 8'sh2E;  8'd114: sin_val = 8'sh2B;  8'd115: sin_val = 8'sh28;
        8'd116: sin_val = 8'sh25;  8'd117: sin_val = 8'sh22;  8'd118: sin_val = 8'sh1F;  8'd119: sin_val = 8'sh1C;
        8'd120: sin_val = 8'sh19;  8'd121: sin_val = 8'sh16;  8'd122: sin_val = 8'sh13;  8'd123: sin_val = 8'sh10;
        8'd124: sin_val = 8'sh0C;  8'd125: sin_val = 8'sh09;  8'd126: sin_val = 8'sh06;  8'd127: sin_val = 8'sh03;
        8'd128: sin_val = 8'sh00;  8'd129: sin_val = -8'sh03;  8'd130: sin_val = -8'sh06;  8'd131: sin_val = -8'sh09;
        8'd132: sin_val = -8'sh0C;  8'd133: sin_val = -8'sh10;  8'd134: sin_val = -8'sh13;  8'd135: sin_val = -8'sh16;
        8'd136: sin_val = -8'sh19;  8'd137: sin_val = -8'sh1C;  8'd138: sin_val = -8'sh1F;  8'd139: sin_val = -8'sh22;
        8'd140: sin_val = -8'sh25;  8'd141: sin_val = -8'sh28;  8'd142: sin_val = -8'sh2B;  8'd143: sin_val = -8'sh2E;
        8'd144: sin_val = -8'sh31;  8'd145: sin_val = -8'sh33;  8'd146: sin_val = -8'sh36;  8'd147: sin_val = -8'sh39;
        8'd148: sin_val = -8'sh3C;  8'd149: sin_val = -8'sh3F;  8'd150: sin_val = -8'sh41;  8'd151: sin_val = -8'sh44;
        8'd152: sin_val = -8'sh47;  8'd153: sin_val = -8'sh49;  8'd154: sin_val = -8'sh4C;  8'd155: sin_val = -8'sh4E;
        8'd156: sin_val = -8'sh51;  8'd157: sin_val = -8'sh53;  8'd158: sin_val = -8'sh55;  8'd159: sin_val = -8'sh58;
        8'd160: sin_val = -8'sh5A;  8'd161: sin_val = -8'sh5C;  8'd162: sin_val = -8'sh5E;  8'd163: sin_val = -8'sh60;
        8'd164: sin_val = -8'sh62;  8'd165: sin_val = -8'sh64;  8'd166: sin_val = -8'sh66;  8'd167: sin_val = -8'sh68;
        8'd168: sin_val = -8'sh6A;  8'd169: sin_val = -8'sh6B;  8'd170: sin_val = -8'sh6D;  8'd171: sin_val = -8'sh6F;
        8'd172: sin_val = -8'sh70;  8'd173: sin_val = -8'sh71;  8'd174: sin_val = -8'sh73;  8'd175: sin_val = -8'sh74;
        8'd176: sin_val = -8'sh75;  8'd177: sin_val = -8'sh76;  8'd178: sin_val = -8'sh78;  8'd179: sin_val = -8'sh79;
        8'd180: sin_val = -8'sh7A;  8'd181: sin_val = -8'sh7A;  8'd182: sin_val = -8'sh7B;  8'd183: sin_val = -8'sh7C;
        8'd184: sin_val = -8'sh7D;  8'd185: sin_val = -8'sh7D;  8'd186: sin_val = -8'sh7E;  8'd187: sin_val = -8'sh7E;
        8'd188: sin_val = -8'sh7E;  8'd189: sin_val = -8'sh7F;  8'd190: sin_val = -8'sh7F;  8'd191: sin_val = -8'sh7F;
        8'd192: sin_val = -8'sh7F;  8'd193: sin_val = -8'sh7F;  8'd194: sin_val = -8'sh7F;  8'd195: sin_val = -8'sh7F;
        8'd196: sin_val = -8'sh7E;  8'd197: sin_val = -8'sh7E;  8'd198: sin_val = -8'sh7E;  8'd199: sin_val = -8'sh7D;
        8'd200: sin_val = -8'sh7D;  8'd201: sin_val = -8'sh7C;  8'd202: sin_val = -8'sh7B;  8'd203: sin_val = -8'sh7A;
        8'd204: sin_val = -8'sh7A;  8'd205: sin_val = -8'sh79;  8'd206: sin_val = -8'sh78;  8'd207: sin_val = -8'sh76;
        8'd208: sin_val = -8'sh75;  8'd209: sin_val = -8'sh74;  8'd210: sin_val = -8'sh73;  8'd211: sin_val = -8'sh71;
        8'd212: sin_val = -8'sh70;  8'd213: sin_val = -8'sh6F;  8'd214: sin_val = -8'sh6D;  8'd215: sin_val = -8'sh6B;
        8'd216: sin_val = -8'sh6A;  8'd217: sin_val = -8'sh68;  8'd218: sin_val = -8'sh66;  8'd219: sin_val = -8'sh64;
        8'd220: sin_val = -8'sh62;  8'd221: sin_val = -8'sh60;  8'd222: sin_val = -8'sh5E;  8'd223: sin_val = -8'sh5C;
        8'd224: sin_val = -8'sh5A;  8'd225: sin_val = -8'sh58;  8'd226: sin_val = -8'sh55;  8'd227: sin_val = -8'sh53;
        8'd228: sin_val = -8'sh51;  8'd229: sin_val = -8'sh4E;  8'd230: sin_val = -8'sh4C;  8'd231: sin_val = -8'sh49;
        8'd232: sin_val = -8'sh47;  8'd233: sin_val = -8'sh44;  8'd234: sin_val = -8'sh41;  8'd235: sin_val = -8'sh3F;
        8'd236: sin_val = -8'sh3C;  8'd237: sin_val = -8'sh39;  8'd238: sin_val = -8'sh36;  8'd239: sin_val = -8'sh33;
        8'd240: sin_val = -8'sh31;  8'd241: sin_val = -8'sh2E;  8'd242: sin_val = -8'sh2B;  8'd243: sin_val = -8'sh28;
        8'd244: sin_val = -8'sh25;  8'd245: sin_val = -8'sh22;  8'd246: sin_val = -8'sh1F;  8'd247: sin_val = -8'sh1C;
        8'd248: sin_val = -8'sh19;  8'd249: sin_val = -8'sh16;  8'd250: sin_val = -8'sh13;  8'd251: sin_val = -8'sh10;
        8'd252: sin_val = -8'sh0C;  8'd253: sin_val = -8'sh09;  8'd254: sin_val = -8'sh06;  8'd255: sin_val = -8'sh03;
        default: sin_val = 8'sh00;
    endcase
end

// 幅度缩放：sample = sin_val * AMP / 128 (右移7位)
wire signed [31:0] sin_mult = $signed(sin_val) * $signed(AMP);
wire signed [23:0] sin_scaled = sin_mult[30:7];

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        O_i2s_BCLK      <= 1'b0;
        O_i2s_LRCK      <= 1'b0;
        O_i2s_DOUT      <= 1'b0;
        S_bit_cnt       <= 6'd0;
        S_shift_reg     <= 64'd0;
        S_phase_acc     <= 32'd0;
        S_sample_word   <= 24'sd0;
        S_sample_next   <= 24'sd0;
        S_note_idx      <= 3'd0;
        S_note_frame_cnt<= 16'd0;
    end
    else begin
        O_i2s_BCLK <= ~O_i2s_BCLK;

        if (O_i2s_BCLK == 1'b1) begin
            O_i2s_DOUT  <= S_shift_reg[63];
            S_shift_reg <= {S_shift_reg[62:0], 1'b0};

            if (S_bit_cnt == 6'd63) begin
                S_bit_cnt <= 6'd0;

                if (O_i2s_LRCK == 1'b0) begin
                    // 左声道发完，右声道复用同一个样本
                    O_i2s_LRCK  <= 1'b1;
                    S_shift_reg <= {S_sample_word[23:0], 40'd0};
                end
                else begin
                    // 右声道发完，进入下一帧样本：DDS正弦波
                    O_i2s_LRCK  <= 1'b0;

                    S_phase_acc   <= S_phase_acc + W_note_inc;
                    S_sample_next <= sin_scaled;       // 正弦波样本(替代原方波)
                    S_sample_word <= sin_scaled;
                    S_shift_reg   <= {sin_scaled[23:0], 40'd0};

                    // 八度音阶循环
                    if (S_note_frame_cnt == NOTE_HOLD_FRAMES - 1) begin
                        S_note_frame_cnt <= 16'd0;
                        if (S_note_idx == 3'd7)
                            S_note_idx <= 3'd0;
                        else
                            S_note_idx <= S_note_idx + 3'd1;
                    end
                    else begin
                        S_note_frame_cnt <= S_note_frame_cnt + 16'd1;
                    end
                end
            end
            else begin
                S_bit_cnt <= S_bit_cnt + 6'd1;
            end
        end
    end
end

endmodule

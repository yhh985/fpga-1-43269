// 16x16 glyphs, 2-bit gray level per pixel, MSB is leftmost.
// Character selection belongs to the outer case(rom_char_sel).
// 0-23: original glyphs; 24-28: existing mode glyphs; 13/29/30/31: blank.
// The shared OSD ROM must read its muxed rom_char_y row coordinate.
        5'd0: begin
            case(rom_char_y)
                4'd0: font_row = 32'h0FFFFFF0;
                4'd1: font_row = 32'h0C0C0030;
                4'd2: font_row = 32'h0C2FFF30;
                4'd3: font_row = 32'h0CA81D30;
                4'd4: font_row = 32'h0D8AB430;
                4'd5: font_row = 32'h0C1BE030;
                4'd6: font_row = 32'h0DE41BB0;
                4'd7: font_row = 32'h0C0E4030;
                4'd8: font_row = 32'h0C01B430;
                4'd9: font_row = 32'h0C7E4030;
                4'd10: font_row = 32'h0C06FC30;
                4'd11: font_row = 32'h0FFFFFF0;
                4'd12: font_row = 32'h0C000030;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd1: begin
            case(rom_char_y)
                4'd0: font_row = 32'h07FFFFF8;
                4'd1: font_row = 32'h0700C000;
                4'd2: font_row = 32'h073FFFE0;
                4'd3: font_row = 32'h073400A0;
                4'd4: font_row = 32'h073FFFE0;
                4'd5: font_row = 32'h073400A0;
                4'd6: font_row = 32'h073FFFE0;
                4'd7: font_row = 32'h0A3433E0;
                4'd8: font_row = 32'h0A0C31C0;
                4'd9: font_row = 32'h0C2C30E0;
                4'd10: font_row = 32'h1CB07034;
                4'd11: font_row = 32'h20C7E014;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd2: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00300000;
                4'd1: font_row = 32'h00FFFC00;
                4'd2: font_row = 32'h03802C00;
                4'd3: font_row = 32'h0E007000;
                4'd4: font_row = 32'h2FFFFFD0;
                4'd5: font_row = 32'h070280D0;
                4'd6: font_row = 32'h070280D0;
                4'd7: font_row = 32'h07FFFFD0;
                4'd8: font_row = 32'h070000D0;
                4'd9: font_row = 32'h07000000;
                4'd10: font_row = 32'h03000028;
                4'd11: font_row = 32'h03FFFFF4;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd3: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h00700000;
                4'd2: font_row = 32'h00600000;
                4'd3: font_row = 32'h1FFFFFF4;
                4'd4: font_row = 32'h00A00000;
                4'd5: font_row = 32'h00D03000;
                4'd6: font_row = 32'h00D830A0;
                4'd7: font_row = 32'h01CD71C0;
                4'd8: font_row = 32'h0346B740;
                4'd9: font_row = 32'h0700DC00;
                4'd10: font_row = 32'h0D038B00;
                4'd11: font_row = 32'h241E02D0;
                4'd12: font_row = 32'h00E00074;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd4: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h0000C000;
                4'd2: font_row = 32'h07FFFFF8;
                4'd3: font_row = 32'h070C0300;
                4'd4: font_row = 32'h07FFFFF4;
                4'd5: font_row = 32'h070C0300;
                4'd6: font_row = 32'h060FFF00;
                4'd7: font_row = 32'h0A000000;
                4'd8: font_row = 32'h0ABFFFC0;
                4'd9: font_row = 32'h0D0D0740;
                4'd10: font_row = 32'h0C03AD00;
                4'd11: font_row = 32'h1C07FD00;
                4'd12: font_row = 32'h26E402B4;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd5: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h00016BF0;
                4'd2: font_row = 32'h03FFA940;
                4'd3: font_row = 32'h03000000;
                4'd4: font_row = 32'h03000000;
                4'd5: font_row = 32'h03FFFFD0;
                4'd6: font_row = 32'h033801C0;
                4'd7: font_row = 32'h031C0380;
                4'd8: font_row = 32'h070B0B00;
                4'd9: font_row = 32'h0603FC00;
                4'd10: font_row = 32'h0D01F800;
                4'd11: font_row = 32'h1C2F5F90;
                4'd12: font_row = 32'h25E401B4;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd6: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h035FFFF8;
                4'd2: font_row = 32'h03402800;
                4'd3: font_row = 32'h03D03400;
                4'd4: font_row = 32'h1BB07000;
                4'd5: font_row = 32'h2B60F700;
                4'd6: font_row = 32'h2742F6C0;
                4'd7: font_row = 32'h034374E0;
                4'd8: font_row = 32'h034E3434;
                4'd9: font_row = 32'h036C3418;
                4'd10: font_row = 32'h03703400;
                4'd11: font_row = 32'h03403400;
                4'd12: font_row = 32'h03403400;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd7: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h0A0FFFF0;
                4'd2: font_row = 32'h0A0C0030;
                4'd3: font_row = 32'h0A0C0030;
                4'd4: font_row = 32'h0A0C0030;
                4'd5: font_row = 32'h0A0C0030;
                4'd6: font_row = 32'h0A0FFFF0;
                4'd7: font_row = 32'h0A0C0030;
                4'd8: font_row = 32'h0A0C0030;
                4'd9: font_row = 32'h0A0C0030;
                4'd10: font_row = 32'h0A0C0030;
                4'd11: font_row = 32'h0A0FFFF0;
                4'd12: font_row = 32'h0A0C0030;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd8: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h00007400;
                4'd2: font_row = 32'h1D00EC00;
                4'd3: font_row = 32'h07074700;
                4'd4: font_row = 32'h002DA1E0;
                4'd5: font_row = 32'h00A03428;
                4'd6: font_row = 32'h00000000;
                4'd7: font_row = 32'h033FFFE0;
                4'd8: font_row = 32'h070002D0;
                4'd9: font_row = 32'h0E0D0B00;
                4'd10: font_row = 32'h0C02EC00;
                4'd11: font_row = 32'h1C007C00;
                4'd12: font_row = 32'h00000700;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd9: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h000056F0;
                4'd2: font_row = 32'h1FEBE900;
                4'd3: font_row = 32'h1CA62490;
                4'd4: font_row = 32'h1CA319C0;
                4'd5: font_row = 32'h1CAFFFF4;
                4'd6: font_row = 32'h1FE1C000;
                4'd7: font_row = 32'h1CAFFFF8;
                4'd8: font_row = 32'h1CA24000;
                4'd9: font_row = 32'h1CA3FFD0;
                4'd10: font_row = 32'h1FDA7680;
                4'd11: font_row = 32'h1C1C2F40;
                4'd12: font_row = 32'h0037E6F8;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd10: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h0BFFFFE0;
                4'd2: font_row = 32'h00000000;
                4'd3: font_row = 32'h00000000;
                4'd4: font_row = 32'h00000000;
                4'd5: font_row = 32'h00000000;
                4'd6: font_row = 32'h00000000;
                4'd7: font_row = 32'h00000000;
                4'd8: font_row = 32'h00000000;
                4'd9: font_row = 32'h00000000;
                4'd10: font_row = 32'h2FFFFFF8;
                4'd11: font_row = 32'h00000000;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd11: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h00C03400;
                4'd2: font_row = 32'h02BFFFF8;
                4'd3: font_row = 32'h03003400;
                4'd4: font_row = 32'h070FFFE0;
                4'd5: font_row = 32'h0F0C00A0;
                4'd6: font_row = 32'h2F0FFFE0;
                4'd7: font_row = 32'h270C00A0;
                4'd8: font_row = 32'h070FFFE0;
                4'd9: font_row = 32'h070C00A0;
                4'd10: font_row = 32'h070FFFE0;
                4'd11: font_row = 32'h070C00A0;
                4'd12: font_row = 32'h077FFFFC;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd12: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h00024000;
                4'd2: font_row = 32'h1FFFFFF4;
                4'd3: font_row = 32'h01800240;
                4'd4: font_row = 32'h01FFFF40;
                4'd5: font_row = 32'h01800240;
                4'd6: font_row = 32'h00000000;
                4'd7: font_row = 32'h1FFFFFF4;
                4'd8: font_row = 32'h1C000034;
                4'd9: font_row = 32'h003FFC00;
                4'd10: font_row = 32'h00701C18;
                4'd11: font_row = 32'h02D01C28;
                4'd12: font_row = 32'h1E400FF4;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd13: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h00000000;
                4'd2: font_row = 32'h00000000;
                4'd3: font_row = 32'h00000000;
                4'd4: font_row = 32'h00000000;
                4'd5: font_row = 32'h00000000;
                4'd6: font_row = 32'h00000000;
                4'd7: font_row = 32'h00000000;
                4'd8: font_row = 32'h00000000;
                4'd9: font_row = 32'h00000000;
                4'd10: font_row = 32'h00000000;
                4'd11: font_row = 32'h00000000;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd14: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h000BF000;
                4'd2: font_row = 32'h002D3C00;
                4'd3: font_row = 32'h00381D00;
                4'd4: font_row = 32'h00300E00;
                4'd5: font_row = 32'h00700E00;
                4'd6: font_row = 32'h00700E00;
                4'd7: font_row = 32'h00700E00;
                4'd8: font_row = 32'h00700D00;
                4'd9: font_row = 32'h00340C00;
                4'd10: font_row = 32'h002D3800;
                4'd11: font_row = 32'h000BE000;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd15: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h0000D000;
                4'd2: font_row = 32'h000BD000;
                4'd3: font_row = 32'h002ED000;
                4'd4: font_row = 32'h0000D000;
                4'd5: font_row = 32'h0000D000;
                4'd6: font_row = 32'h0000D000;
                4'd7: font_row = 32'h0000D000;
                4'd8: font_row = 32'h0000D000;
                4'd9: font_row = 32'h0000D000;
                4'd10: font_row = 32'h0000D000;
                4'd11: font_row = 32'h0000D000;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd16: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h000FE000;
                4'd2: font_row = 32'h00387C00;
                4'd3: font_row = 32'h00001C00;
                4'd4: font_row = 32'h00001C00;
                4'd5: font_row = 32'h00002C00;
                4'd6: font_row = 32'h0000B400;
                4'd7: font_row = 32'h0003D000;
                4'd8: font_row = 32'h000F0000;
                4'd9: font_row = 32'h003C0000;
                4'd10: font_row = 32'h00355400;
                4'd11: font_row = 32'h003FFE00;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd17: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h000BE000;
                4'd2: font_row = 32'h00247800;
                4'd3: font_row = 32'h00002C00;
                4'd4: font_row = 32'h00002800;
                4'd5: font_row = 32'h00007400;
                4'd6: font_row = 32'h000FD000;
                4'd7: font_row = 32'h00007800;
                4'd8: font_row = 32'h00001C00;
                4'd9: font_row = 32'h00001C00;
                4'd10: font_row = 32'h00347C00;
                4'd11: font_row = 32'h002FE000;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd18: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h00007400;
                4'd2: font_row = 32'h0000F400;
                4'd3: font_row = 32'h0002F400;
                4'd4: font_row = 32'h00033400;
                4'd5: font_row = 32'h000E3400;
                4'd6: font_row = 32'h002C3400;
                4'd7: font_row = 32'h00703400;
                4'd8: font_row = 32'h00FFFF00;
                4'd9: font_row = 32'h00003400;
                4'd10: font_row = 32'h00003400;
                4'd11: font_row = 32'h00003400;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd19: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h001FF800;
                4'd2: font_row = 32'h001C0000;
                4'd3: font_row = 32'h001C0000;
                4'd4: font_row = 32'h002C0000;
                4'd5: font_row = 32'h00280000;
                4'd6: font_row = 32'h002FE000;
                4'd7: font_row = 32'h00057C00;
                4'd8: font_row = 32'h00001C00;
                4'd9: font_row = 32'h00001C00;
                4'd10: font_row = 32'h00007C00;
                4'd11: font_row = 32'h002FE000;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd20: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h0002F800;
                4'd2: font_row = 32'h000F4800;
                4'd3: font_row = 32'h002C0000;
                4'd4: font_row = 32'h00380000;
                4'd5: font_row = 32'h0037F400;
                4'd6: font_row = 32'h003D2C00;
                4'd7: font_row = 32'h00340E00;
                4'd8: font_row = 32'h00340E00;
                4'd9: font_row = 32'h00380D00;
                4'd10: font_row = 32'h001D2C00;
                4'd11: font_row = 32'h000BF000;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd21: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h007FFE00;
                4'd2: font_row = 32'h00155C00;
                4'd3: font_row = 32'h00002800;
                4'd4: font_row = 32'h00003000;
                4'd5: font_row = 32'h0000A000;
                4'd6: font_row = 32'h0000D000;
                4'd7: font_row = 32'h0002C000;
                4'd8: font_row = 32'h00038000;
                4'd9: font_row = 32'h00034000;
                4'd10: font_row = 32'h00070000;
                4'd11: font_row = 32'h000B0000;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd22: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h000BE000;
                4'd2: font_row = 32'h002D3C00;
                4'd3: font_row = 32'h00381C00;
                4'd4: font_row = 32'h00381C00;
                4'd5: font_row = 32'h000C3400;
                4'd6: font_row = 32'h001FF400;
                4'd7: font_row = 32'h003D6C00;
                4'd8: font_row = 32'h00700E00;
                4'd9: font_row = 32'h00700E00;
                4'd10: font_row = 32'h003D2C00;
                4'd11: font_row = 32'h000BF400;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd23: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h000BE000;
                4'd2: font_row = 32'h002D7C00;
                4'd3: font_row = 32'h00341C00;
                4'd4: font_row = 32'h00700D00;
                4'd5: font_row = 32'h00740E00;
                4'd6: font_row = 32'h003C2E00;
                4'd7: font_row = 32'h000FED00;
                4'd8: font_row = 32'h00000C00;
                4'd9: font_row = 32'h00002C00;
                4'd10: font_row = 32'h0024B400;
                4'd11: font_row = 32'h001FD000;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd24: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h01C00C00;
                4'd2: font_row = 32'h01C00C00;
                4'd3: font_row = 32'h01C00C00;
                4'd4: font_row = 32'h01FFFFFC;
                4'd5: font_row = 32'h01C00000;
                4'd6: font_row = 32'h01C00000;
                4'd7: font_row = 32'h01FFFE00;
                4'd8: font_row = 32'h01C00A00;
                4'd9: font_row = 32'h02800A00;
                4'd10: font_row = 32'h03000A00;
                4'd11: font_row = 32'h0A000A00;
                4'd12: font_row = 32'h0C000A00;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd25: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h0300C340;
                4'd2: font_row = 32'h031FFFF8;
                4'd3: font_row = 32'h0300C340;
                4'd4: font_row = 32'h2FFBFFF0;
                4'd5: font_row = 32'h070A0070;
                4'd6: font_row = 32'h0BDBFFF0;
                4'd7: font_row = 32'h0F7A0070;
                4'd8: font_row = 32'h2B0BFFF0;
                4'd9: font_row = 32'h23002400;
                4'd10: font_row = 32'h032FFFF8;
                4'd11: font_row = 32'h0301AB40;
                4'd12: font_row = 32'h032E00B8;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd26: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h00007280;
                4'd2: font_row = 32'h00007090;
                4'd3: font_row = 32'h3FFFFFF8;
                4'd4: font_row = 32'h00003000;
                4'd5: font_row = 32'h00003000;
                4'd6: font_row = 32'h1FFF7000;
                4'd7: font_row = 32'h00A03400;
                4'd8: font_row = 32'h00A02800;
                4'd9: font_row = 32'h00A01C18;
                4'd10: font_row = 32'h00A00D28;
                4'd11: font_row = 32'h06FFC774;
                4'd12: font_row = 32'h2E9401F0;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd27: begin
            case(rom_char_y)
                4'd0: font_row = 32'h2FFC00C0;
                4'd1: font_row = 32'h001C00C0;
                4'd2: font_row = 32'h0C1EFFFC;
                4'd3: font_row = 32'h0D2800D0;
                4'd4: font_row = 32'h0334C0C0;
                4'd5: font_row = 32'h02F0E0C0;
                4'd6: font_row = 32'h00E070C0;
                4'd7: font_row = 32'h00F024C0;
                4'd8: font_row = 32'h02B800C0;
                4'd9: font_row = 32'h070C00C0;
                4'd10: font_row = 32'h1D0900C0;
                4'd11: font_row = 32'h24003FC0;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd28: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h0D00D000;
                4'd2: font_row = 32'h0D00D000;
                4'd3: font_row = 32'h0D00D034;
                4'd4: font_row = 32'h0D00D0E0;
                4'd5: font_row = 32'h0FFDD380;
                4'd6: font_row = 32'h0D00EE00;
                4'd7: font_row = 32'h0D00F400;
                4'd8: font_row = 32'h0D00D000;
                4'd9: font_row = 32'h0D00D018;
                4'd10: font_row = 32'h0D1CD028;
                4'd11: font_row = 32'h0FF4D038;
                4'd12: font_row = 32'h0E00BFF0;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd29: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h00000000;
                4'd2: font_row = 32'h00000000;
                4'd3: font_row = 32'h00000000;
                4'd4: font_row = 32'h00000000;
                4'd5: font_row = 32'h00000000;
                4'd6: font_row = 32'h00000000;
                4'd7: font_row = 32'h00000000;
                4'd8: font_row = 32'h00000000;
                4'd9: font_row = 32'h00000000;
                4'd10: font_row = 32'h00000000;
                4'd11: font_row = 32'h00000000;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd30: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h00000000;
                4'd2: font_row = 32'h00000000;
                4'd3: font_row = 32'h00000000;
                4'd4: font_row = 32'h00000000;
                4'd5: font_row = 32'h00000000;
                4'd6: font_row = 32'h00000000;
                4'd7: font_row = 32'h00000000;
                4'd8: font_row = 32'h00000000;
                4'd9: font_row = 32'h00000000;
                4'd10: font_row = 32'h00000000;
                4'd11: font_row = 32'h00000000;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        5'd31: begin
            case(rom_char_y)
                4'd0: font_row = 32'h00000000;
                4'd1: font_row = 32'h00000000;
                4'd2: font_row = 32'h00000000;
                4'd3: font_row = 32'h00000000;
                4'd4: font_row = 32'h00000000;
                4'd5: font_row = 32'h00000000;
                4'd6: font_row = 32'h00000000;
                4'd7: font_row = 32'h00000000;
                4'd8: font_row = 32'h00000000;
                4'd9: font_row = 32'h00000000;
                4'd10: font_row = 32'h00000000;
                4'd11: font_row = 32'h00000000;
                4'd12: font_row = 32'h00000000;
                4'd13: font_row = 32'h00000000;
                4'd14: font_row = 32'h00000000;
                4'd15: font_row = 32'h00000000;
                default: font_row = 32'h00000000;
            endcase
        end
        default: font_row = 32'h00000000;

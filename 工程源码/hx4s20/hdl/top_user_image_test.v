// Dedicated manual, card-free test build with the user's original images.
module top_user_image_test(
    input clk, input key1, input key2, input key3, input key4,
    input sw1, input sw2, input sw3, input sw4,
    output [5:0] seg_sel, output [7:0] seg_data,
    output HDMI_CLK_P, output HDMI_D2_P, output HDMI_D1_P, output HDMI_D0_P,
    output HDMI_DDC_SCL, inout HDMI_DDC_SDA,
    output sd_ncs, output sd_dclk, output sd_mosi, input sd_miso,
    output led1, output led2
);
top #(.USER_IMAGE_TEST(1), .MANUAL_ONLY(1)) u_test(
    .clk(clk),.key1(key1),.key2(key2),.key3(key3),.key4(key4),
    .sw1(sw1),.sw2(sw2),.sw3(sw3),.sw4(sw4),
    .seg_sel(seg_sel),.seg_data(seg_data),
    .HDMI_CLK_P(HDMI_CLK_P),.HDMI_D2_P(HDMI_D2_P),
    .HDMI_D1_P(HDMI_D1_P),.HDMI_D0_P(HDMI_D0_P),
    .HDMI_DDC_SCL(HDMI_DDC_SCL),.HDMI_DDC_SDA(HDMI_DDC_SDA),
    .sd_ncs(sd_ncs),.sd_dclk(sd_dclk),.sd_mosi(sd_mosi),.sd_miso(sd_miso),
    .led1(led1),.led2(led2)
);
endmodule

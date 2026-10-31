// Input range 0..99. Compare/subtract avoids a general divider in the FPGA.
function [7:0] decimal_two_digits;
    input [6:0] value;
    reg [3:0] tens;
    reg [6:0] remainder;
    begin
        if      (value >= 7'd90) begin tens=9; remainder=value-7'd90; end
        else if (value >= 7'd80) begin tens=8; remainder=value-7'd80; end
        else if (value >= 7'd70) begin tens=7; remainder=value-7'd70; end
        else if (value >= 7'd60) begin tens=6; remainder=value-7'd60; end
        else if (value >= 7'd50) begin tens=5; remainder=value-7'd50; end
        else if (value >= 7'd40) begin tens=4; remainder=value-7'd40; end
        else if (value >= 7'd30) begin tens=3; remainder=value-7'd30; end
        else if (value >= 7'd20) begin tens=2; remainder=value-7'd20; end
        else if (value >= 7'd10) begin tens=1; remainder=value-7'd10; end
        else                   begin tens=0; remainder=value; end
        decimal_two_digits={tens,remainder[3:0]};
    end
endfunction

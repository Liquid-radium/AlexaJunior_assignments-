module MAC_unit_1 (
    input  [7:0] A,
    input  [7:0] B,
    input        clock,
    input        reset_p,
    output reg [15:0] S
);

    reg [16:0] sum;

    always @(posedge clock or posedge reset_p) begin
        if (reset_p) begin
            S <= 16'd0;
        end else begin
            sum = S + A*B;         // blocking assignment is used because we need to calculate sum(a temporary variable) immediately to check for saturation(otherwise the previous value of sum will be used and condition for saturation is not met)
            if (sum > 16'hFFFF)
                S <= 16'hFFFF;     // condition for saturation
            else
                S <= sum[15:0];    // normal accumulation
        end
    end
endmodule

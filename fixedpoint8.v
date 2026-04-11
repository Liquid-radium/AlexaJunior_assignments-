// ============================================================
// fixedpoint8.v
// Q1.7 Fixed-point arithmetic units for LeNet-5 Accelerator
//
// Format  : Q1.7 signed fixed-point, 8-bit
//           Bit 7    = sign
//           Bits 6:0 = fractional (weight 2^-1 ... 2^-7)
//           Range    : -1.0 to +0.9921875
//
// Modules : fp8_add      - saturating Q1.7 adder (combinational)
//           fp32_to_fp8  - Q2.14→Q1.7 with round-nearest + saturate
// ============================================================

// ──────────────────────────────────────────────────────────────
// fp8_add : result = a + b  (Q1.7, saturating)
// ──────────────────────────────────────────────────────────────
module fp8_add (
    input  wire signed [7:0] a,
    input  wire signed [7:0] b,
    output reg  signed [7:0] result,
    output reg               overflow
);
    localparam signed [7:0] MAX_POS = 8'h7F;
    localparam signed [7:0] MAX_NEG = 8'h80;

    wire signed [8:0] sum_full = {a[7], a} + {b[7], b};

    always @(*) begin
        if      (sum_full[8] == 1'b0 && sum_full[7] == 1'b1) begin
            result = MAX_POS; overflow = 1'b1;
        end else if (sum_full[8] == 1'b1 && sum_full[7] == 1'b0) begin
            result = MAX_NEG; overflow = 1'b1;
        end else begin
            result = sum_full[7:0]; overflow = 1'b0;
        end
    end
endmodule


// ──────────────────────────────────────────────────────────────
// fp32_to_fp8 : 32-bit accumulator → Q1.7 (round + saturate)
// Input is a Q2.14 value stored in the lower 16 bits of a 32-bit
// accumulator (upper bits are sign extension).
// Extraction: bits [14:7] = Q1.7, bit [6] = round bit.
// ──────────────────────────────────────────────────────────────
module fp32_to_fp8 (
    input  wire signed [31:0] in_val,
    output reg  signed [7:0]  out_val,
    output reg                overflow
);
    // High-zone overflow: any significant bits above bit 14
    wire pos_high_ovf = (!in_val[31]) && (|in_val[31:15]);
    wire neg_high_ovf = ( in_val[31]) && (!(&in_val[31:15]));

    wire signed [7:0] truncated = in_val[14:7];
    wire              round_bit = in_val[6];

    // Round-to-nearest-half-up: add round bit to truncated Q1.7
    wire signed [8:0] rounded = {truncated[7], truncated} + {8'b0, round_bit};

    always @(*) begin
        if (pos_high_ovf) begin
            out_val = 8'h7F; overflow = 1'b1;
        end else if (neg_high_ovf) begin
            out_val = 8'h80; overflow = 1'b1;
        end else if (rounded[8] == 1'b0 && rounded[7] == 1'b1) begin
            out_val = 8'h7F; overflow = 1'b1;
        end else if (rounded[8] == 1'b1 && rounded[7] == 1'b0) begin
            out_val = 8'h80; overflow = 1'b1;
        end else begin
            out_val = rounded[7:0]; overflow = 1'b0;
        end
    end
endmodule
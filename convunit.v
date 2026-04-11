// ============================================================
// convunit.v  (Q1.7 version)
// Multiply-Accumulate unit for LeNet-5 Hardware Accelerator
//
// Computes: acc += weight * patch_data  (pipelined, 3-stage)
//
// Format:
//   Inputs  : Q1.7 (8-bit signed)
//   Internal: 32-bit signed accumulator
//   Output  : Q1.7 (8-bit, rounded + clipped from accumulator)
//
// Latency from last_elem pulse to valid result: 3 cycles
//
// Control:
//   acc_clear  : synchronous reset of accumulator (before new pixel)
//   acc_en     : perform MAC this cycle
//   last_elem  : pulse on final element → result latched 2 cycles later
//   overflow   : asserted when result is saturated
// ============================================================
module convunit (
    input  wire        clk,
    input  wire        rst_n,

    input  wire signed [7:0]  patch_data,
    input  wire signed [7:0]  weight,

    input  wire        acc_en,
    input  wire        acc_clear,
    input  wire        last_elem,

    output reg  acc_valid,
    output reg  signed [7:0]  result,
    output reg                overflow
);

// ── Stage 1: multiply ────────────────────────────────────────
wire signed [15:0] mult_wire = patch_data * weight; // Q2.14

reg signed [15:0] mult_reg;
reg               acc_en_d1, last_elem_d1, acc_clear_d1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mult_reg     <= 16'sd0;
        acc_en_d1    <= 1'b0;
        last_elem_d1 <= 1'b0;
        acc_clear_d1 <= 1'b0;
    end else begin
        acc_en_d1    <= acc_en;
        last_elem_d1 <= last_elem;
        acc_clear_d1 <= acc_clear;
        mult_reg     <= acc_en ? mult_wire : 16'sd0;
    end
end

// ── Stage 2: accumulate (32-bit) ─────────────────────────────
reg signed [31:0] accumulator;
reg               last_elem_d2;
wire signed [31:0] acc_next = accumulator + {{16{mult_reg[15]}}, mult_reg};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        accumulator  <= 32'sd0;
        last_elem_d2 <= 1'b0;
    end else begin
        last_elem_d2 <= last_elem_d1;

        if (acc_clear_d1 && !last_elem_d1) begin
            accumulator <= 32'sd0;
        end else if (acc_en_d1 || last_elem_d1) begin
            accumulator <= acc_next;
        end
    end
end

// ── Stage 3: Q2.14 → Q1.7 conversion ────────────────────────
reg signed [31:0] acc_final;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) acc_final <= 32'sd0;
    else if (last_elem_d1) acc_final <= acc_next;
end

wire signed [7:0] conv_out;
wire              conv_ovf;

fp32_to_fp8 u_formatter (
    .in_val  (acc_final),
    .out_val (conv_out),
    .overflow(conv_ovf)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        result    <= 8'sd0;
        overflow  <= 1'b0;
        acc_valid <= 1'b0;
    end else if (last_elem_d2) begin
        result    <= conv_out;
        overflow  <= conv_ovf;
        acc_valid <= 1'b1;
    end else begin
        overflow  <= 1'b0;
        acc_valid <= 1'b0;
        result    <= 8'sd0;
    end
end

endmodule
// ─────────────────────────────────────────────────────────────
// fc_stage_ctrl - wraps fc + optional ReLU
// ─────────────────────────────────────────────────────────────
module fc_stage_ctrl #(
    parameter IN_NODES   = 2944,
    parameter OUT_NODES  = 120,
    parameter DATA_WIDTH = 8,
    parameter USE_RELU   = 1,
    parameter BUF_CNT_W  = 12
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   start,

    output wire [$clog2(IN_NODES * OUT_NODES + OUT_NODES)-1:0] wgt_addr,
    input  wire [DATA_WIDTH-1:0]  wgt_dout,

    input  wire [DATA_WIDTH-1:0]  in_data,
    input  wire                   in_valid,
    output wire                   in_ready,

    output wire [DATA_WIDTH-1:0]  out_data,
    output wire                   out_valid,
    input  wire                   out_ready,

    output wire                   all_done,
    output wire                   ovf_flag
);
    wire [DATA_WIDTH-1:0] fc_out_raw;
    wire                  fc_out_valid;

    fc #(
        .IN_NODES(IN_NODES), .OUT_NODES(OUT_NODES), .DATA_WIDTH(DATA_WIDTH)
    ) u_fc (
        .clk      (clk),   .rst_n    (rst_n),  .start    (start),
        .wgt_addr (wgt_addr),           .wgt_dout (wgt_dout),
        .in_data  (in_data),            .in_valid (in_valid),
        .in_ready (in_ready),
        .out_data (fc_out_raw),         .out_valid(fc_out_valid),
        .out_ready(out_ready),
        .all_done (all_done),           .ovf_flag (ovf_flag)
    );

    generate
        if (USE_RELU) begin : gen_relu
            assign out_data  = fc_out_raw[DATA_WIDTH-1] ? {DATA_WIDTH{1'b0}} : fc_out_raw;
            assign out_valid = fc_out_valid;
        end else begin : gen_no_relu
            assign out_data  = fc_out_raw;
            assign out_valid = fc_out_valid;
        end
    endgenerate

endmodule
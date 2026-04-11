// ============================================================
// conv1_relu_pool1_ctrl.v
//
// Glue logic for the Conv1 → ReLU → MaxPool1 pipeline stage.
//
// Data flow:
//   Input BRAM  : ifmap0  (1×40×101 = 4040 pixels, Q1.7)
//   Conv1       : 1→6 ch, 5×5, pad=2  → 6×40×101 feature maps
//   ReLU        : combinational
//   MaxPool1    : 2×2 stride-2, per channel → 6×20×50 feature maps
//   Output BRAM : ofmap1  (6×20×50 = 6000 words)
//
// Coordinate ordering written to ofmap1:
//   addr = ch * (20*50) + row * 50 + col
// ============================================================
module conv1_relu_pool1_ctrl #(
    // Conv1 parameters
    parameter IN_CH      = 1,
    parameter OUT_CH     = 6,
    parameter IMG_W      = 101,
    parameter IMG_H      = 40,
    parameter PADDING    = 2,
    parameter KERNEL     = 5,
    parameter DATA_WIDTH = 8,

    // Derived
    parameter OUT_W      = IMG_W + 2*PADDING - KERNEL + 1,  // 101
    parameter OUT_H      = IMG_H + 2*PADDING - KERNEL + 1,  // 40

    // Pool output dimensions
    parameter POOL_W     = OUT_W / 2,   // 50
    parameter POOL_H     = OUT_H / 2,   // 20

    // BRAM address widths
    parameter IFMAP_DEPTH  = IMG_W * IMG_H * IN_CH,   // 4040
    parameter OFMAP1_DEPTH = OUT_CH * POOL_W * POOL_H, // 6000

    parameter IFMAP_ADDR_W  = $clog2(IFMAP_DEPTH),
    parameter OFMAP1_ADDR_W = $clog2(OFMAP1_DEPTH),

    // Conv output coordinate widths
    parameter OCH_W    = $clog2(OUT_CH),
    parameter OUT_H_W  = $clog2(OUT_H),
    parameter OUT_W_W  = $clog2(OUT_W),
    parameter WGT_ADDR_W = $clog2(OUT_CH * IN_CH * KERNEL * KERNEL + OUT_CH)
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output reg  done,

    // Input feature map BRAM (read port)
    output wire [IFMAP_ADDR_W-1:0]  ifmap_addr,
    input  wire [DATA_WIDTH-1:0]    ifmap_dout,

    // Weight BRAM (read port)
    output wire [WGT_ADDR_W-1:0]   wgt_addr,
    input  wire [DATA_WIDTH-1:0]    wgt_dout,

    // Output feature map BRAM (write port → ofmap1)
    output reg  [OFMAP1_ADDR_W-1:0] ofmap1_wr_addr,
    output reg  [DATA_WIDTH-1:0]    ofmap1_wr_data,
    output reg                      ofmap1_wr_en
);

// ── Conv1 output stream ──────────────────────────────────────
wire signed [DATA_WIDTH-1:0] conv_data;
wire [OCH_W-1:0]             conv_filter;
wire [OUT_H_W-1:0]           conv_row;
wire [OUT_W_W-1:0]           conv_col;
wire                         conv_valid;
wire                         conv_ready;
wire                         conv_all_done;
wire                         conv_ovf;

// Use a dedicated wgt_addr wire driven by convlayer
wire [WGT_ADDR_W-1:0] conv_wgt_addr;
assign wgt_addr = conv_wgt_addr;

convlayer #(
    .IN_CH(IN_CH),   .OUT_CH(OUT_CH),
    .IMG_W(IMG_W),   .IMG_H(IMG_H),
    .PADDING(PADDING),.KERNEL(KERNEL),
    .DATA_WIDTH(DATA_WIDTH)
) u_conv1 (
    .clk(clk),         .rst_n(rst_n),  .start(start),
    .wgt_addr(conv_wgt_addr), .wgt_dout(wgt_dout),
    .bram_addr(ifmap_addr),   .bram_dout(ifmap_dout),
    .out_data(conv_data),     .out_filter(conv_filter),
    .out_row(conv_row),       .out_col(conv_col),
    .out_valid(conv_valid),   .out_ready(conv_ready),
    .all_done(conv_all_done), .ovf_flag(conv_ovf)
);

// ── ReLU (combinational) ─────────────────────────────────────
wire signed [DATA_WIDTH-1:0] relu_data;
wire                         relu_valid;
wire                         relu_ready;

relu u_relu (
    .in_data(conv_data),    .in_valid(conv_valid),   .in_ready(conv_ready),
    .out_data(relu_data),   .out_valid(relu_valid),  .out_ready(relu_ready)
);

// ── MaxPool (multi-channel) ──────────────────────────────────
wire signed [DATA_WIDTH-1:0] pool_out_data;
wire                         pool_out_valid;
wire                         pool_out_ready;
wire                         pool_all_done;
wire                         pool_in_ready;

// Pool start: when convlayer starts a new filter
reg pool_start;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) pool_start <= 0;
    else        pool_start <= start; // fire one cycle after conv start
end

assign relu_ready = pool_in_ready;

maxpool_multi #(
    .IN_CH(OUT_CH), .IN_W(OUT_W), .IN_H(OUT_H), .DATA_WIDTH(DATA_WIDTH)
) u_pool1 (
    .clk(clk),       .rst_n(rst_n),    .start(pool_start),
    .in_data(relu_data),    .in_ch(conv_filter),
    .in_valid(relu_valid),  .in_ready(pool_in_ready),
    .out_data(pool_out_data), .out_valid(pool_out_valid),
    .out_ready(pool_out_ready), .all_done(pool_all_done)
);

// ── Write pooled output into ofmap1 BRAM ─────────────────────
// Address layout: ch * POOL_H * POOL_W + row * POOL_W + col
// We use a simple counter since the pool outputs pixels in raster order
// per channel (channels are sequential in maxpool_multi).
localparam POOL_PIX = POOL_W * POOL_H; // 1000 per channel
localparam PIX_W    = $clog2(POOL_PIX);
localparam CH_W     = $clog2(OUT_CH);

reg [PIX_W-1:0] pix_cnt;  // pixel within current channel
reg [CH_W-1:0]  ch_cnt;   // current channel being written

assign pool_out_ready = 1'b1; // always accept

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pix_cnt      <= 0;
        ch_cnt       <= 0;
        ofmap1_wr_en <= 0;
        ofmap1_wr_addr <= 0;
        ofmap1_wr_data <= 0;
        done         <= 0;
    end else begin
        ofmap1_wr_en <= 0;
        done         <= 0;

        if (start) begin
            pix_cnt <= 0;
            ch_cnt  <= 0;
        end

        if (pool_out_valid) begin
            ofmap1_wr_en   <= 1;
            ofmap1_wr_data <= pool_out_data;
            ofmap1_wr_addr <= ch_cnt * POOL_PIX + pix_cnt;

            if (pix_cnt == POOL_PIX - 1) begin
                pix_cnt <= 0;
                ch_cnt  <= ch_cnt + 1;
            end else begin
                pix_cnt <= pix_cnt + 1;
            end
        end

        if (pool_all_done) begin
            done <= 1;
        end
    end
end

endmodule
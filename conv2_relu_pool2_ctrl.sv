// ============================================================
// conv2_relu_pool2_ctrl.v
//
// Conv2 → ReLU → MaxPool2 pipeline stage.
//
//   Input BRAM  : ofmap1  (6×20×50 = 6000 words, Q1.7)
//   Conv2       : 6→16 ch, 5×5, pad=0 → 16×16×46
//   ReLU        : combinational
//   MaxPool2    : 2×2 stride-2 → 16×8×23 = 2944 words
//   Output BRAM : ofmap2  (2944 words)
//
// ofmap2 address: ch * (8*23) + row * 23 + col
// ============================================================
module conv2_relu_pool2_ctrl #(
    parameter IN_CH      = 6,
    parameter OUT_CH     = 16,
    parameter IMG_W      = 50,
    parameter IMG_H      = 20,
    parameter PADDING    = 0,
    parameter KERNEL     = 5,
    parameter DATA_WIDTH = 8,

    parameter OUT_W      = IMG_W + 2*PADDING - KERNEL + 1,  // 46
    parameter OUT_H      = IMG_H + 2*PADDING - KERNEL + 1,  // 16

    parameter POOL_W     = OUT_W / 2,    // 23
    parameter POOL_H     = OUT_H / 2,    // 8

    parameter IFMAP_DEPTH  = IMG_W * IMG_H * IN_CH,    // 6000
    parameter OFMAP2_DEPTH = OUT_CH * POOL_W * POOL_H, // 2944

    parameter IFMAP_ADDR_W  = $clog2(IFMAP_DEPTH),
    parameter OFMAP2_ADDR_W = $clog2(OFMAP2_DEPTH),

    parameter OCH_W      = $clog2(OUT_CH),
    parameter OUT_H_W    = $clog2(OUT_H),
    parameter OUT_W_W    = $clog2(OUT_W),
    parameter WGT_ADDR_W = $clog2(OUT_CH * IN_CH * KERNEL * KERNEL + OUT_CH)
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output reg  done,

    output wire [IFMAP_ADDR_W-1:0]  ifmap_addr,
    input  wire [DATA_WIDTH-1:0]    ifmap_dout,

    output wire [WGT_ADDR_W-1:0]   wgt_addr,
    input  wire [DATA_WIDTH-1:0]    wgt_dout,

    output reg  [OFMAP2_ADDR_W-1:0] ofmap2_wr_addr,
    output reg  [DATA_WIDTH-1:0]    ofmap2_wr_data,
    output reg                      ofmap2_wr_en
);

wire signed [DATA_WIDTH-1:0] conv_data;
wire [OCH_W-1:0]             conv_filter;
wire [OUT_H_W-1:0]           conv_row;
wire [OUT_W_W-1:0]           conv_col;
wire                         conv_valid;
wire                         conv_ready;
wire                         conv_all_done;
wire [WGT_ADDR_W-1:0]        conv_wgt_addr;

assign wgt_addr = conv_wgt_addr;

convlayer #(
    .IN_CH(IN_CH),   .OUT_CH(OUT_CH),
    .IMG_W(IMG_W),   .IMG_H(IMG_H),
    .PADDING(PADDING),.KERNEL(KERNEL),
    .DATA_WIDTH(DATA_WIDTH)
) u_conv2 (
    .clk(clk),         .rst_n(rst_n),  .start(start),
    .wgt_addr(conv_wgt_addr), .wgt_dout(wgt_dout),
    .bram_addr(ifmap_addr),   .bram_dout(ifmap_dout),
    .out_data(conv_data),     .out_filter(conv_filter),
    .out_row(conv_row),       .out_col(conv_col),
    .out_valid(conv_valid),   .out_ready(conv_ready),
    .all_done(conv_all_done), .ovf_flag()
);

wire signed [DATA_WIDTH-1:0] relu_data;
wire                         relu_valid, relu_ready;

relu u_relu (
    .in_data(conv_data),   .in_valid(conv_valid),  .in_ready(conv_ready),
    .out_data(relu_data),  .out_valid(relu_valid), .out_ready(relu_ready)
);

wire signed [DATA_WIDTH-1:0] pool_out_data;
wire                         pool_out_valid, pool_all_done, pool_in_ready;

reg pool_start;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) pool_start <= 0;
    else        pool_start <= start;
end

assign relu_ready = pool_in_ready;

maxpool_multi #(
    .IN_CH(OUT_CH), .IN_W(OUT_W), .IN_H(OUT_H), .DATA_WIDTH(DATA_WIDTH)
) u_pool2 (
    .clk(clk),      .rst_n(rst_n),    .start(pool_start),
    .in_data(relu_data),    .in_ch(conv_filter),
    .in_valid(relu_valid),  .in_ready(pool_in_ready),
    .out_data(pool_out_data), .out_valid(pool_out_valid),
    .out_ready(1'b1),         .all_done(pool_all_done)
);

localparam POOL_PIX = POOL_W * POOL_H;  // 184 per channel
localparam PIX_W    = $clog2(POOL_PIX);
localparam CH_W     = $clog2(OUT_CH);

reg [PIX_W-1:0] pix_cnt;
reg [CH_W-1:0]  ch_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pix_cnt        <= 0;  ch_cnt        <= 0;
        ofmap2_wr_en   <= 0;  ofmap2_wr_addr <= 0;
        ofmap2_wr_data <= 0;  done           <= 0;
    end else begin
        ofmap2_wr_en <= 0;
        done         <= 0;

        if (start) begin
            pix_cnt <= 0;
            ch_cnt  <= 0;
        end

        if (pool_out_valid) begin
            ofmap2_wr_en   <= 1;
            ofmap2_wr_data <= pool_out_data;
            ofmap2_wr_addr <= ch_cnt * POOL_PIX + pix_cnt;

            if (pix_cnt == POOL_PIX - 1) begin
                pix_cnt <= 0;
                ch_cnt  <= ch_cnt + 1;
            end else begin
                pix_cnt <= pix_cnt + 1;
            end
        end

        if (pool_all_done) done <= 1;
    end
end

endmodule
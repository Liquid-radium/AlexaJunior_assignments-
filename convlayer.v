// ============================================================
// convlayer.v  (Q1.7, Verilog-2001 compatible, corrected)
//
// Default parameters = Conv1:
//   IN_CH=1, OUT_CH=6, IMG_W=101, IMG_H=40, PADDING=2
//
// Conv2 override:
//   IN_CH=6, OUT_CH=16, IMG_W=50, IMG_H=20, PADDING=0
//
// BRAM layout (weight+bias combined):
//   [0 .. WGT_TOTAL-1]          = weights  (filter-major order)
//   [WGT_TOTAL .. +OUT_CH - 1]  = biases
// ============================================================
module convlayer #(
    parameter IN_CH      = 1,
    parameter OUT_CH     = 6,
    parameter IMG_W      = 101,
    parameter IMG_H      = 40,
    parameter PADDING    = 2,
    parameter KERNEL     = 5,
    parameter DATA_WIDTH = 8,

    parameter OUT_W      = IMG_W + 2*PADDING - KERNEL + 1,
    parameter OUT_H      = IMG_H + 2*PADDING - KERNEL + 1,
    parameter KK         = KERNEL * KERNEL,
    parameter MAC_TOTAL  = IN_CH * KK,
    parameter WGT_TOTAL  = OUT_CH * MAC_TOTAL,

    parameter IFMAP_ADDR_W = $clog2(IMG_W * IMG_H * IN_CH),
    parameter WGT_ADDR_W   = $clog2(WGT_TOTAL + OUT_CH),  // include bias space
    parameter OFMAP_ADDR_W = $clog2(OUT_H * OUT_W * OUT_CH),

    parameter OCH_W      = $clog2(OUT_CH),
    parameter OUT_H_W    = $clog2(OUT_H),
    parameter OUT_W_W    = $clog2(OUT_W),
    parameter MAC_CNT_W  = $clog2(MAC_TOTAL),
    parameter ICH_W      = (IN_CH > 1) ? $clog2(IN_CH) : 1
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,

    // Weight+bias BRAM
    output reg  [WGT_ADDR_W-1:0]       wgt_addr,
    input  wire [DATA_WIDTH-1:0]        wgt_dout,

    // Input feature map BRAM
    output wire [IFMAP_ADDR_W-1:0]     bram_addr,
    input  wire [DATA_WIDTH-1:0]        bram_dout,

    // Output stream
    output reg  signed [DATA_WIDTH-1:0] out_data,
    output reg  [OCH_W-1:0]             out_filter,
    output reg  [OUT_H_W-1:0]           out_row,
    output reg  [OUT_W_W-1:0]           out_col,
    output reg                           out_valid,
    input  wire                          out_ready,

    output reg  all_done,
    output reg  ovf_flag
);

// ── FSM states ───────────────────────────────────────────────
localparam IDLE      = 3'd0;
localparam LOAD_BIAS = 3'd1;
localparam WAIT_BIAS = 3'd2;
localparam WAIT_WGT  = 3'd7;
localparam MAC_RUN   = 3'd3;
localparam MAC_DRAIN = 3'd4;
localparam ADD_BIAS  = 3'd5;
localparam OUTPUT_ST = 3'd6;

reg [2:0]           state;
reg [OCH_W-1:0]     filter;
reg [MAC_CNT_W-1:0] mac_cnt;
reg [1:0]           drain_cnt;
reg signed [7:0]    bias_reg;
reg                 rf_start_r, rf_next_r;
reg                 cu_acc_en, cu_acc_clear, cu_last_elem;
reg signed [7:0]    cu_weight;

wire                      rf_patch_valid, rf_all_done;
wire signed [DATA_WIDTH-1:0] rf_patch_data;
wire [OUT_H_W-1:0]        rf_out_row;
wire [OUT_W_W-1:0]        rf_out_col;

rfselector #(
    .IMG_W(IMG_W),       .IMG_H(IMG_H),
    .IN_CHANNELS(IN_CH), .PADDING(PADDING),
    .KERNEL(KERNEL),     .DATA_WIDTH(DATA_WIDTH)
) u_rf (
    .clk(clk),           .rst_n(rst_n),
    .start(rf_start_r),  .next_patch(rf_next_r),
    .bram_addr(bram_addr),.bram_dout(bram_dout),
    .patch_data(rf_patch_data), .patch_valid(rf_patch_valid),
    .patch_done(),
    .out_row(rf_out_row), .out_col(rf_out_col),
    .channel(),           .all_done(rf_all_done)
);

wire signed [7:0] cu_result;
wire              cu_overflow;

convunit u_mac (
    .clk(clk),                .rst_n(rst_n),
    .patch_data(rf_patch_data),.weight(cu_weight),
    .acc_en(cu_acc_en),       .acc_clear(cu_acc_clear),
    .last_elem(cu_last_elem),
    .acc_valid(),
    .result(cu_result),        .overflow(cu_overflow)
);

wire signed [7:0] biased_result;
wire              bias_ovf;

fp8_add u_bias_add (
    .a(cu_result),  .b(bias_reg),
    .result(biased_result), .overflow(bias_ovf)
);

reg [OUT_H_W-1:0] saved_row;
reg [OUT_W_W-1:0] saved_col;

// Precompute weight base address for current filter (avoids repeated multiply)
wire [WGT_ADDR_W-1:0] filter_base = filter * MAC_TOTAL;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state        <= IDLE;    filter       <= 0;   mac_cnt    <= 0;
        drain_cnt    <= 0;       wgt_addr     <= 0;
        bias_reg     <= 8'sd0;   cu_weight    <= 8'sd0;
        cu_acc_en    <= 0;       cu_acc_clear <= 0;   cu_last_elem <= 0;
        out_data     <= 8'sd0;   out_filter   <= 0;   out_row    <= 0;
        out_col      <= 0;       out_valid    <= 0;   all_done   <= 0;
        ovf_flag     <= 0;       rf_start_r   <= 0;   rf_next_r  <= 0;
        saved_row    <= 0;       saved_col    <= 0;
    end else begin
        // Default: clear single-cycle pulses
        cu_acc_en    <= 0;
        cu_acc_clear <= 0;
        cu_last_elem <= 0;
        out_valid    <= 0;
        all_done     <= 0;
        rf_start_r   <= 0;
        rf_next_r    <= 0;

        case (state)
            IDLE: begin
                if (start) begin
                    filter   <= 0;
                    ovf_flag <= 0;
                    state    <= LOAD_BIAS;
                end
            end

            LOAD_BIAS: begin
                // Bias lives at WGT_TOTAL + filter
                wgt_addr <= WGT_TOTAL[WGT_ADDR_W-1:0]
                            + {{(WGT_ADDR_W-OCH_W){1'b0}}, filter};
                state <= WAIT_BIAS;
            end

            WAIT_BIAS: begin
                bias_reg     <= wgt_dout;
                cu_acc_clear <= 1;
                mac_cnt      <= 0;
                wgt_addr     <= filter_base;
                state        <= WAIT_WGT;
            end

            WAIT_WGT: begin
                rf_start_r <= 1;
                state      <= MAC_RUN;
            end

            MAC_RUN: begin
                if (rf_patch_valid) begin
                    cu_weight <= wgt_dout;
                    cu_acc_en <= 1;
                    mac_cnt   <= mac_cnt + 1;

                    if (mac_cnt == MAC_TOTAL - 1) begin
                        cu_last_elem <= 1;
                        drain_cnt    <= 0;
                        saved_row    <= rf_out_row;
                        saved_col    <= rf_out_col;
                        state        <= MAC_DRAIN;
                    end else begin
                        // Pre-fetch next weight: base + (mac_cnt+1)
                        wgt_addr <= filter_base
                                  + {{(WGT_ADDR_W-MAC_CNT_W){1'b0}}, mac_cnt} + 1;
                    end
                end
            end

            MAC_DRAIN: begin
                drain_cnt <= drain_cnt + 1;
                if (drain_cnt == 2'd1) state <= ADD_BIAS;
            end

            ADD_BIAS: begin
                ovf_flag <= ovf_flag | cu_overflow | bias_ovf;
                state    <= OUTPUT_ST;
            end

            OUTPUT_ST: begin
                out_data   <= biased_result;
                out_filter <= filter;
                out_row    <= saved_row;
                out_col    <= saved_col;
                out_valid  <= 1;

                if (out_ready) begin
                    if (rf_all_done) begin
                        if (filter == OUT_CH - 1) begin
                            all_done <= 1;
                            state    <= IDLE;
                        end else begin
                            filter     <= filter + 1;
                            state      <= LOAD_BIAS;
                        end
                    end else begin
                        rf_next_r    <= 1;
                        cu_acc_clear <= 1;
                        mac_cnt      <= 0;
                        wgt_addr     <= filter_base;
                        state        <= MAC_RUN;
                    end
                end
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule
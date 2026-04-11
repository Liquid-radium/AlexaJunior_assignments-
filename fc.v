// ============================================================
// fc.v  - fixed version
//
// Fix vs previous version:
//   Line 93: out_cnt[WGT_AW-1:0] caused Synth 8-524 because
//   out_cnt is $clog2(OUT_NODES) bits wide but WGT_AW=19.
//   You cannot part-select MORE bits than the register has.
//   Fix: use {{(WGT_AW - OUT_CNT_W){1'b0}}, out_cnt} to
//   zero-extend out_cnt to WGT_AW bits before arithmetic.
// ============================================================

module fc #(
    parameter IN_NODES   = 2944,
    parameter OUT_NODES  = 120,
    parameter DATA_WIDTH = 8
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   start,

    output reg  [$clog2(IN_NODES * OUT_NODES + OUT_NODES)-1:0] wgt_addr,
    input  wire [DATA_WIDTH-1:0]  wgt_dout,

    input  wire [DATA_WIDTH-1:0]  in_data,
    input  wire                   in_valid,
    output reg                    in_ready,

    output reg  [DATA_WIDTH-1:0]  out_data,
    output reg                    out_valid,
    input  wire                   out_ready,

    output reg                    all_done,
    output reg                    ovf_flag
);
    localparam WGT_AW    = $clog2(IN_NODES * OUT_NODES + OUT_NODES);
    localparam IN_CNT_W  = $clog2(IN_NODES);
    localparam OUT_CNT_W = $clog2(OUT_NODES);
    localparam ACC_W     = DATA_WIDTH * 2 + IN_CNT_W;

    // zero-extend helpers - avoids part-select-out-of-range
    // by always producing WGT_AW-wide values for address arithmetic
    `define ZX_IN(x)  {{(WGT_AW-IN_CNT_W){1'b0}},  (x)}
    `define ZX_OUT(x) {{(WGT_AW-OUT_CNT_W){1'b0}}, (x)}
    `define ZX_IN_P   {{(WGT_AW-IN_CNT_W){1'b0}},  {IN_CNT_W{1'b1}}}  // IN_NODES as WGT_AW

    localparam [WGT_AW-1:0] WGT_IN  = IN_NODES [WGT_AW-1:0];
    localparam [WGT_AW-1:0] WGT_OUT = OUT_NODES[WGT_AW-1:0];
    localparam [WGT_AW-1:0] BIAS_BASE = WGT_IN * WGT_OUT;  // IN*OUT = bias start

    localparam [2:0]
        IDLE      = 3'd0,
        LOAD_BIAS = 3'd1,
        WAIT_BIAS = 3'd2,
        WAIT_WGT  = 3'd7,
        MAC_RUN   = 3'd3,
        MAC_DRAIN = 3'd4,
        ADD_BIAS  = 3'd5,
        OUTPUT_ST = 3'd6;

    reg [2:0]  state;
    reg signed [ACC_W-1:0]      acc;
    reg signed [DATA_WIDTH-1:0] bias_reg;
    reg [IN_CNT_W-1:0]          in_cnt;
    reg [OUT_CNT_W-1:0]         out_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            wgt_addr  <= '0;
            acc       <= '0;
            bias_reg  <= '0;
            in_cnt    <= '0;
            out_cnt   <= '0;
            in_ready  <= 1'b0;
            out_valid <= 1'b0;
            out_data  <= '0;
            all_done  <= 1'b0;
            ovf_flag  <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            all_done  <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        out_cnt  <= '0;
                        // bias for neuron 0 is at IN*OUT + 0
                        wgt_addr <= BIAS_BASE;
                        state    <= LOAD_BIAS;
                    end
                end

                LOAD_BIAS: state <= WAIT_BIAS;

                WAIT_BIAS: begin
                    bias_reg <= $signed(wgt_dout);
                    acc      <= '0;
                    in_cnt   <= '0;
                    in_ready <= 1'b1;
                    // weight row for out_cnt: out_cnt * IN_NODES
                    // zero-extend out_cnt to WGT_AW before multiply
                    wgt_addr <= {{(WGT_AW-OUT_CNT_W){1'b0}}, out_cnt} * WGT_IN;
                    state    <= WAIT_WGT;
                end

                WAIT_WGT: state <= MAC_RUN;

                MAC_RUN: begin
                    if (in_valid && in_ready) begin
                        acc      <= acc + $signed(in_data) * $signed(wgt_dout);
                        wgt_addr <= wgt_addr + 1'b1;
                        in_cnt   <= in_cnt + 1'b1;
                        if (in_cnt == IN_NODES[IN_CNT_W-1:0] - 1'b1) begin
                            in_ready <= 1'b0;
                            state    <= MAC_DRAIN;
                        end
                    end
                end

                MAC_DRAIN: state <= ADD_BIAS;

                ADD_BIAS: begin
                    acc   <= acc + {{(ACC_W-DATA_WIDTH){bias_reg[DATA_WIDTH-1]}}, bias_reg};
                    state <= OUTPUT_ST;
                end

                OUTPUT_ST: begin
                    // saturate to signed DATA_WIDTH range [-128, +127]
                    if ($signed(acc) > $signed({{(ACC_W-DATA_WIDTH){1'b0}}, {1'b0,{(DATA_WIDTH-1){1'b1}}}})) begin
                        out_data <= {1'b0, {(DATA_WIDTH-1){1'b1}}};  // +127
                        ovf_flag <= 1'b1;
                    end else if ($signed(acc) < $signed({{(ACC_W-DATA_WIDTH){1'b1}}, {1'b1,{(DATA_WIDTH-1){1'b0}}}})) begin
                        out_data <= {1'b1, {(DATA_WIDTH-1){1'b0}}};  // -128
                        ovf_flag <= 1'b1;
                    end else begin
                        out_data <= acc[DATA_WIDTH-1:0];
                        ovf_flag <= 1'b0;
                    end
                    out_valid <= 1'b1;

                    if (out_cnt == OUT_NODES[OUT_CNT_W-1:0] - 1'b1) begin
                        all_done <= 1'b1;
                        state    <= IDLE;
                    end else begin
                        out_cnt  <= out_cnt + 1'b1;
                        // next bias: BIAS_BASE + out_cnt + 1
                        wgt_addr <= BIAS_BASE
                                    + {{(WGT_AW-OUT_CNT_W){1'b0}}, out_cnt}
                                    + 1'b1;
                        state    <= LOAD_BIAS;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    `undef ZX_IN
    `undef ZX_OUT
    `undef ZX_IN_P

endmodule


// ─────────────────────────────────────────────────────────────
// fc_input_buffer - sync reset, BRAM-inferred
// ─────────────────────────────────────────────────────────────
module fc_input_buffer #(
    parameter DEPTH      = 2944,
    parameter DATA_WIDTH = 8,
    parameter CNT_W      = 12
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire [DATA_WIDTH-1:0]  wr_data,
    input  wire                   wr_en,
    output wire                   wr_done,
    output reg  [DATA_WIDTH-1:0]  rd_data,
    input  wire                   rd_en,
    output wire                   rd_done,
    input  wire                   buf_start
);
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] buf_mem [0:DEPTH-1];

    reg [CNT_W-1:0] wr_addr, rd_addr;
    reg wr_done_r, rd_done_r;

    assign wr_done = wr_done_r;
    assign rd_done = rd_done_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_addr   <= '0;  rd_addr   <= '0;
            wr_done_r <= 1'b0; rd_done_r <= 1'b0;
            rd_data   <= '0;
        end else begin
            wr_done_r <= 1'b0;
            rd_done_r <= 1'b0;
            if (buf_start) begin wr_addr <= '0; rd_addr <= '0; end
            if (wr_en) begin
                buf_mem[wr_addr] <= wr_data;
                if (wr_addr == DEPTH[CNT_W-1:0] - 1'b1) begin
                    wr_addr <= '0; wr_done_r <= 1'b1;
                end else wr_addr <= wr_addr + 1'b1;
            end
            if (rd_en) begin
                rd_data <= buf_mem[rd_addr];
                if (rd_addr == DEPTH[CNT_W-1:0] - 1'b1) begin
                    rd_addr <= '0; rd_done_r <= 1'b1;
                end else rd_addr <= rd_addr + 1'b1;
            end
        end
    end
endmodule



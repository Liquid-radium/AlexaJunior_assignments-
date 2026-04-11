// ============================================================
// relu_maxpool.v  - fixed version
//
// Fixes vs previous broken version:
//  1. relu: kept purely combinational with in_valid/in_ready/
//     out_valid/out_ready passthrough ports to match what
//     conv1_relu_pool1_ctrl and conv2_relu_pool2_ctrl connect.
//
//  2. maxpool: sync reset only (no async) to fix BRAM inference
//     and Synth 8-7137 set/reset priority conflict.
//     Fixed Synth 8-196 "conditional could not be resolved to
//     a constant" by replacing IN_W[$clog2(IN_W)-1:0] with
//     a proper localparam.
//
//  3. maxpool_multi: restored .in_ch() port that ctrl files
//     connect as .in_ch(conv_filter).
// ============================================================

// ─────────────────────────────────────────────────────────────
// relu - combinational with valid/ready passthrough
// ─────────────────────────────────────────────────────────────
module relu #(
    parameter DATA_WIDTH = 8
)(
    input  wire signed [DATA_WIDTH-1:0] in_data,
    input  wire                         in_valid,
    output wire                         in_ready,
    output wire signed [DATA_WIDTH-1:0] out_data,
    output wire                         out_valid,
    input  wire                         out_ready
);
    assign out_data  = in_data[DATA_WIDTH-1] ? {DATA_WIDTH{1'b0}} : in_data;
    assign out_valid = in_valid;
    assign in_ready  = out_ready;
endmodule


// ─────────────────────────────────────────────────────────────
// maxpool - 2×2 stride-2, single channel, sync reset
// ─────────────────────────────────────────────────────────────
module maxpool #(
    parameter IN_W       = 101,
    parameter IN_H       = 40,
    parameter DATA_WIDTH = 8
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   start,
    input  wire [DATA_WIDTH-1:0]  in_data,
    input  wire                   in_valid,
    output reg                    in_ready,
    output reg  [DATA_WIDTH-1:0]  out_data,
    output reg                    out_valid,
    output reg                    done
);
    // Use localparams for constants used in comparisons -
    // avoids Synth 8-196 "could not resolve to a constant"
    localparam COL_W   = $clog2(IN_W + 1);
    localparam ROW_W   = $clog2(IN_H + 1);
    localparam [COL_W-1:0] MAX_COL = IN_W - 1;
    localparam [ROW_W-1:0] MAX_ROW = IN_H - 2;   // last valid top-row start

    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] line_buf [0:IN_W-1];

    reg [COL_W-1:0] col;
    reg [ROW_W-1:0] row;
    reg [DATA_WIDTH-1:0] tl, bl;

    localparam [1:0] S_FILL = 2'd0, S_POOL = 2'd1, S_DONE = 2'd2;
    reg [1:0] state;

    function [DATA_WIDTH-1:0] umax;
        input [DATA_WIDTH-1:0] a, b;
        umax = (a >= b) ? a : b;
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_FILL;
            col       <= '0;
            row       <= '0;
            in_ready  <= 1'b0;
            out_valid <= 1'b0;
            out_data  <= '0;
            done      <= 1'b0;
            tl        <= '0;
            bl        <= '0;
        end else begin
            out_valid <= 1'b0;
            done      <= 1'b0;

            case (state)
                S_FILL: begin
                    if (start) begin
                        col      <= '0;
                        row      <= '0;
                        in_ready <= 1'b1;
                    end else if (in_valid && in_ready) begin
                        line_buf[col] <= in_data;
                        if (col == MAX_COL) begin
                            col   <= '0;
                            row   <= row + 1'b1;
                            state <= S_POOL;
                        end else
                            col <= col + 1'b1;
                    end
                end

                S_POOL: begin
                    if (in_valid && in_ready) begin
                        if (col[0] == 1'b0) begin
                            // even col: latch left column
                            tl <= line_buf[col];
                            bl <= in_data;
                        end else begin
                            // odd col: full 2×2 window ready, emit max
                            out_data  <= umax(umax(tl, line_buf[col]),
                                              umax(bl, in_data));
                            out_valid <= 1'b1;
                        end

                        if (col == MAX_COL) begin
                            col <= '0;
                            if (row >= MAX_ROW) begin
                                in_ready <= 1'b0;
                                state    <= S_DONE;
                            end else begin
                                row   <= row + 2'd2;
                                state <= S_FILL;
                            end
                        end else
                            col <= col + 1'b1;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_FILL;
                end

                default: state <= S_FILL;
            endcase
        end
    end

endmodule


// ─────────────────────────────────────────────────────────────
// maxpool_multi - one maxpool per channel, channel selected by in_ch
// ─────────────────────────────────────────────────────────────
module maxpool_multi #(
    parameter IN_CH      = 6,
    parameter IN_W       = 101,
    parameter IN_H       = 40,
    parameter DATA_WIDTH = 8
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,

    input  wire [DATA_WIDTH-1:0]         in_data,
    input  wire [$clog2(IN_CH)-1:0]      in_ch,
    input  wire                          in_valid,
    output wire                          in_ready,

    output reg  [DATA_WIDTH-1:0]         out_data,
    output reg                           out_valid,
    input  wire                          out_ready,

    output wire                          all_done
);
    localparam CH_W = $clog2(IN_CH);

    wire [DATA_WIDTH-1:0] ch_out_data [0:IN_CH-1];
    wire                  ch_out_valid[0:IN_CH-1];
    wire                  ch_in_ready [0:IN_CH-1];
    wire                  ch_done     [0:IN_CH-1];

    genvar i;
    generate
        for (i = 0; i < IN_CH; i = i + 1) begin : gen_ch
            maxpool #(.IN_W(IN_W), .IN_H(IN_H), .DATA_WIDTH(DATA_WIDTH)) u_mp (
                .clk      (clk),
                .rst_n    (rst_n),
                .start    (start),
                .in_data  (in_data),
                .in_valid (in_valid && (in_ch == i[CH_W-1:0])),
                .in_ready (ch_in_ready [i]),
                .out_data (ch_out_data [i]),
                .out_valid(ch_out_valid[i]),
                .done     (ch_done     [i])
            );
        end
    endgenerate

    // expose the currently addressed channel's ready signal
    assign in_ready = ch_in_ready[in_ch];

    // all channels done when last channel asserts done
    assign all_done = ch_done[IN_CH-1];

    // serialise outputs: whichever channel has valid data this cycle wins
    // (only one channel produces output at a time in raster order)
    reg [CH_W-1:0] out_ch_sel;

    integer j;
    always @(posedge clk) begin
        if (!rst_n) begin
            out_ch_sel <= '0;
            out_data   <= '0;
            out_valid  <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            // find the lowest-indexed channel with valid output
            for (j = IN_CH-1; j >= 0; j = j - 1) begin
                if (ch_out_valid[j]) begin
                    out_ch_sel <= j[CH_W-1:0];
                    out_data   <= ch_out_data[j];
                    out_valid  <= 1'b1;
                end
            end
        end
    end

endmodule
// ============================================================
// rfselector.v  (Q1.7, Verilog-2001 compatible, corrected)
//
// Extracts 5x5 receptive field patches from a feature map
// stored in BRAM, one element per cycle (serial output).
//
// Conv1: IMG_W=101, IMG_H=40, PADDING=2, IN_CHANNELS=1
// Conv2: IMG_W=50,  IMG_H=20, PADDING=0, IN_CHANNELS=6
// ============================================================
module rfselector #(
    parameter IMG_W       = 101,
    parameter IMG_H       = 40,
    parameter IN_CHANNELS = 1,
    parameter PADDING     = 2,
    parameter KERNEL      = 5,
    parameter DATA_WIDTH  = 8,
    parameter ADDR_WIDTH  = $clog2(IMG_W * IMG_H * IN_CHANNELS),
    parameter OUT_W       = IMG_W + PADDING*2 - KERNEL + 1,
    parameter OUT_H       = IMG_H + PADDING*2 - KERNEL + 1,
    parameter OUT_ROW_W   = $clog2(OUT_H),
    parameter OUT_COL_W   = $clog2(OUT_W),
    parameter CH_W        = (IN_CHANNELS > 1) ? $clog2(IN_CHANNELS) : 1
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        next_patch,

    output reg  [ADDR_WIDTH-1:0]  bram_addr,
    input  wire [DATA_WIDTH-1:0]  bram_dout,

    output reg  [DATA_WIDTH-1:0]  patch_data,
    output reg                    patch_valid,
    output reg                    patch_done,

    output reg  [OUT_ROW_W-1:0]   out_row,
    output reg  [OUT_COL_W-1:0]   out_col,
    output reg  [CH_W-1:0]        channel,

    output reg                    all_done
);

localparam KW       = $clog2(KERNEL);
localparam IN_ROW_W = $clog2(IMG_H);
localparam IN_COL_W = $clog2(IMG_W);

localparam IDLE       = 3'd0;
localparam LOAD_ADDR  = 3'd1;
localparam WAIT_READ  = 3'd2;
localparam OUTPUT_ST  = 3'd3;
localparam PATCH_END  = 3'd4;
localparam ALL_FINISH = 3'd5;

reg [2:0]   state;
reg [KW-1:0]   ki, kj;
reg [CH_W-1:0] ch_idx;

// FIX: Use signed integers for abs coordinate arithmetic (was broken in original)
wire signed [8:0] abs_row = $signed({2'b00, out_row}) + $signed({2'b00, ki}) - $signed(9'(PADDING));
wire signed [8:0] abs_col = $signed({2'b00, out_col}) + $signed({2'b00, kj}) - $signed(9'(PADDING));

wire is_pad = (abs_row < 0) || (abs_row >= $signed(9'(IMG_H)))
           || (abs_col < 0) || (abs_col >= $signed(9'(IMG_W)));

// FIX: pixel_addr was syntactically broken in original (ternary without body)
wire [ADDR_WIDTH-1:0] pixel_addr =
    is_pad ? {ADDR_WIDTH{1'b0}} :
    ( ch_idx  * (IMG_H * IMG_W)
    + abs_row[IN_ROW_W-1:0] * IMG_W
    + abs_col[IN_COL_W-1:0] );

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= IDLE;
        out_row     <= 0; out_col    <= 0; channel    <= 0;
        ki          <= 0; kj         <= 0; ch_idx     <= 0;
        bram_addr   <= 0;
        patch_data  <= 0; patch_valid <= 0;
        patch_done  <= 0; all_done    <= 0;
    end else begin
        patch_valid <= 0;
        patch_done  <= 0;
        all_done    <= 0;

        case (state)

            IDLE: begin
                if (start) begin
                    out_row <= 0; out_col <= 0; channel <= 0;
                    ki <= 0;      kj <= 0;      ch_idx  <= 0;
                    state <= LOAD_ADDR;
                end
            end

            LOAD_ADDR: begin
                if (is_pad) begin
                    state <= OUTPUT_ST;
                end else begin
                    bram_addr <= pixel_addr;
                    state     <= WAIT_READ;
                end
            end

            WAIT_READ: begin
                state <= OUTPUT_ST;
            end

            OUTPUT_ST: begin
                patch_data  <= is_pad ? {DATA_WIDTH{1'b0}} : bram_dout;
                patch_valid <= 1;
                channel     <= ch_idx;

                // Advance: ch_idx (fastest) → kj → ki
                if (ch_idx == IN_CHANNELS - 1) begin
                    ch_idx <= 0;
                    if (kj == KERNEL - 1) begin
                        kj <= 0;
                        if (ki == KERNEL - 1) begin
                            ki    <= 0;
                            state <= PATCH_END;
                        end else begin
                            ki    <= ki + 1;
                            state <= LOAD_ADDR;
                        end
                    end else begin
                        kj    <= kj + 1;
                        state <= LOAD_ADDR;
                    end
                end else begin
                    ch_idx <= ch_idx + 1;
                    state  <= LOAD_ADDR;
                end
            end

            PATCH_END: begin
                patch_done <= 1;
                if (next_patch) begin
                    channel <= 0;
                    if (out_col == OUT_W - 1) begin
                        out_col <= 0;
                        if (out_row == OUT_H - 1) begin
                            out_row <= 0;
                            state   <= ALL_FINISH;
                        end else begin
                            out_row <= out_row + 1;
                            state   <= LOAD_ADDR;
                        end
                    end else begin
                        out_col <= out_col + 1;
                        state   <= LOAD_ADDR;
                    end
                end
            end

            ALL_FINISH: begin
                all_done <= 1;
                if (start) begin
                    out_row <= 0; out_col <= 0; channel <= 0;
                    ki <= 0;      kj <= 0;      ch_idx  <= 0;
                    state <= LOAD_ADDR;
                end
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule
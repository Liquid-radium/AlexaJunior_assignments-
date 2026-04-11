// ============================================================
// argmax.v
// Finds the index of the maximum value in a stream of
// NUM_CLASSES Q1.7 signed values.
// ============================================================
module argmax #(
    parameter NUM_CLASSES = 31,
    parameter DATA_WIDTH  = 8
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,

    input  wire signed [DATA_WIDTH-1:0] in_data,
    input  wire                         in_valid,
    output reg                          in_ready,

    output reg [$clog2(NUM_CLASSES)-1:0] class_idx,
    output reg                           done
);

localparam CNT_W  = $clog2(NUM_CLASSES);
// Most-negative Q1.7 value
localparam [DATA_WIDTH-1:0] MIN_VAL = {1'b1, {(DATA_WIDTH-1){1'b0}}};

localparam IDLE   = 2'd0;
localparam RUN    = 2'd1;
localparam FINISH = 2'd2;

reg [1:0]                   state;
reg [CNT_W-1:0]             cnt;
reg signed [DATA_WIDTH-1:0] max_val;
reg [CNT_W-1:0]             max_idx;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state     <= IDLE;
        cnt       <= 0;
        max_val   <= MIN_VAL;
        max_idx   <= 0;
        class_idx <= 0;
        done      <= 0;
        in_ready  <= 0;
    end else begin
        done <= 0;

        case (state)
            IDLE: begin
                in_ready <= 0;
                if (start) begin
                    cnt      <= 0;
                    max_val  <= MIN_VAL;
                    max_idx  <= 0;
                    in_ready <= 1;
                    state    <= RUN;
                end
            end

            RUN: begin
                in_ready <= 1;
                if (in_valid) begin
                    if (cnt == 0 || in_data > max_val) begin
                        max_val <= in_data;
                        max_idx <= cnt;
                    end
                    if (cnt == (NUM_CLASSES - 1)) begin
                        in_ready <= 0;
                        state    <= FINISH;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end
            end

            FINISH: begin
                class_idx <= max_idx;
                done      <= 1;
                in_ready  <= 0;
                state     <= IDLE;
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule
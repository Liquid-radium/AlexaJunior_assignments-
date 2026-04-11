// ============================================================
// feature_bram.v
// Simple dual-port BRAM: write port (loader), read port (engine)
// Synchronous read, 1-cycle latency.
// ============================================================
module feature_bram #(
    parameter DATA_WIDTH = 8,
    parameter DEPTH      = 1024,
    parameter INIT_FILE  = ""
)(
    input  wire                       clk,

    // Write port
    input  wire [$clog2(DEPTH)-1:0]   wr_addr,
    input  wire [DATA_WIDTH-1:0]      wr_data,
    input  wire                       wr_en,

    // Read port
    input  wire [$clog2(DEPTH)-1:0]   rd_addr,
    output reg  [DATA_WIDTH-1:0]      rd_data
);
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
        rd_data <= mem[rd_addr];
    end
endmodule
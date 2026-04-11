// ============================================================
// kws_top.sv  -  Nexys 4 DDR  /  Artix-7 XC7A100T
//
// Fixes in this version:
//  1. infer_done now LATCHES high and stays lit until the next
//     infer_start rising edge. Previously it pulsed for one
//     83 MHz clock cycle (12 ns) - invisible to any LED.
//  2. infer_start is edge-detected (rising edge only) so that
//     holding BTNC does not re-trigger inference in ST_DONE.
//  3. Button debounce counter (~6 ms at 83 MHz) on infer_start
//     so contact bounce does not cause multiple triggers.
// ============================================================

module kws_top #(
    parameter DATA_WIDTH  = 8,
    parameter NUM_CLASSES = 31,

    parameter IN_CH  = 1,
    parameter IMG_W  = 101,
    parameter IMG_H  = 40,

    parameter IFMAP0_DEPTH = IN_CH * IMG_W * IMG_H,
    parameter WGT1_DEPTH   = 6*1*25   + 6,
    parameter WGT2_DEPTH   = 16*6*25  + 16,
    parameter WGTFC1_DEPTH = 2944*120 + 120,
    parameter WGTFC2_DEPTH = 120*84   + 84,
    parameter WGTFC3_DEPTH = 84*31    + 31,
    parameter OFMAP1_DEPTH = 6000,
    parameter OFMAP2_DEPTH = 2944,

    parameter IFMAP0_AW = $clog2(IFMAP0_DEPTH),
    parameter WGT1_AW   = $clog2(WGT1_DEPTH),
    parameter WGT2_AW   = $clog2(WGT2_DEPTH),
    parameter WGTFC1_AW = $clog2(WGTFC1_DEPTH),
    parameter WGTFC2_AW = $clog2(WGTFC2_DEPTH),
    parameter WGTFC3_AW = $clog2(WGTFC3_DEPTH),
    parameter OFMAP1_AW = $clog2(OFMAP1_DEPTH),
    parameter OFMAP2_AW = $clog2(OFMAP2_DEPTH),
    parameter CLASS_W   = $clog2(NUM_CLASSES)
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   infer_start,
    output wire [15:0]LED
);

reg  [CLASS_W-1:0]     class_out;
wire                   ovf_flag;
 reg                    infer_done;
// ─────────────────────────────────────────────────────────────
// Clock Wizard  (100 MHz → 83.33 MHz)
// ─────────────────────────────────────────────────────────────
wire clk_83, locked;

clk_wiz_0 u_clk_gen (
    .clk_in1  (clk),
    .clk_out1 (clk_83),
    .resetn   (rst_n),  // Direct connection to active-low pin
    .locked   (locked)
);


// ─────────────────────────────────────────────────────────────
// Reset synchroniser  (async assert, sync de-assert)
// ─────────────────────────────────────────────────────────────
(* ASYNC_REG = "TRUE" *) reg rst_sync1, rst_sync2;
wire sys_rst_n = rst_sync2; // This is our internal Active-Low reset

always @(posedge clk_83 or negedge rst_n) begin
    if (!rst_n) begin                   // FIXED: Reset when button is 0
        {rst_sync2, rst_sync1} <= 2'b00;
    end else if (!locked) begin         // Reset if clock isn't ready
        {rst_sync2, rst_sync1} <= 2'b00;
    end else begin
        {rst_sync2, rst_sync1} <= {rst_sync1, 1'b1}; // Release reset
    end
end


// ─────────────────────────────────────────────────────────────
// Button debounce + rising-edge detector for infer_start
//
// Stage 1: 2-FF synchroniser into clk_83 domain.
// Stage 2: require button stable for 2^19 cycles (~6 ms at
//          83 MHz) before registering a level change.
// Stage 3: single-cycle rising-edge pulse.
// ─────────────────────────────────────────────────────────────
reg  btn_s1, btn_s2;          // synchroniser FFs
reg  btn_stable;              // debounced level
reg  [19:0] dbnc_cnt;         // debounce counter
reg  btn_prev;                // previous stable level
wire start_pulse;             // one-cycle rising-edge pulse

// Synchronise raw button
always @(posedge clk_83 or negedge sys_rst_n) begin
    if (!sys_rst_n) {btn_s2, btn_s1} <= 2'b00;
    else            {btn_s2, btn_s1} <= {btn_s1, infer_start};
end

// Debounce
always @(posedge clk_83 or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        dbnc_cnt   <= 20'd0;
        btn_stable <= 1'b0;
    end else if (btn_s2 == btn_stable) begin
        dbnc_cnt <= 20'd0;
    end else begin
        dbnc_cnt <= dbnc_cnt + 1'b1;
        if (&dbnc_cnt) begin               // all bits 1 → 6 ms elapsed
            btn_stable <= btn_s2;
            dbnc_cnt   <= 20'd0;
        end
    end
end

// Edge detect
always @(posedge clk_83 or negedge sys_rst_n) begin
    if (!sys_rst_n) btn_prev <= 1'b0;
    else            btn_prev <= btn_stable;
end

assign start_pulse = btn_stable & ~btn_prev;

// ─────────────────────────────────────────────────────────────
// Feature BRAM  (input image)
// ─────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────
// Feature BRAM (input image) - Updated to load from hex file
// ─────────────────────────────────────────────────────────────
wire [IFMAP0_AW-1:0]  ifmap0_rd_addr;
wire [DATA_WIDTH-1:0] ifmap0_rd_data;

feature_bram #(
    .DATA_WIDTH(DATA_WIDTH),
    .DEPTH(IFMAP0_DEPTH),
    .INIT_FILE("ifmap.hex")        // Load your data here
) u_ifmap0 (
    .clk(clk_83),
    .wr_addr(loader_addr),
    .wr_data(loader_data),
    .wr_en(1'b0),                  // Tied to 0 to prevent accidental overwrites from pins
    .rd_addr(ifmap0_rd_addr),
    .rd_data(ifmap0_rd_data)
);

// ─────────────────────────────────────────────────────────────
// Weight BRAMs
// ─────────────────────────────────────────────────────────────
wire [WGT1_AW-1:0]    wgt1_addr;    wire [DATA_WIDTH-1:0] wgt1_dout;
wire [WGT2_AW-1:0]    wgt2_addr;    wire [DATA_WIDTH-1:0] wgt2_dout;
wire [WGTFC1_AW-1:0]  wgt_fc1_addr; wire [DATA_WIDTH-1:0] wgt_fc1_dout;
wire [WGTFC2_AW-1:0]  wgt_fc2_addr; wire [DATA_WIDTH-1:0] wgt_fc2_dout;
wire [WGTFC3_AW-1:0]  wgt_fc3_addr; wire [DATA_WIDTH-1:0] wgt_fc3_dout;

wgt_bram #(.DATA_WIDTH(DATA_WIDTH),.DEPTH(WGT1_DEPTH),  .INIT_FILE("conv1.hex")) u_wgt1   (.clk(clk_83),.addr(wgt1_addr),   .dout(wgt1_dout));
wgt_bram #(.DATA_WIDTH(DATA_WIDTH),.DEPTH(WGT2_DEPTH),  .INIT_FILE("conv2.hex")) u_wgt2   (.clk(clk_83),.addr(wgt2_addr),   .dout(wgt2_dout));
wgt_bram #(.DATA_WIDTH(DATA_WIDTH),.DEPTH(WGTFC1_DEPTH),.INIT_FILE("fc1.hex"))   u_wgt_fc1(.clk(clk_83),.addr(wgt_fc1_addr),.dout(wgt_fc1_dout));
wgt_bram #(.DATA_WIDTH(DATA_WIDTH),.DEPTH(WGTFC2_DEPTH),.INIT_FILE("fc2.hex"))   u_wgt_fc2(.clk(clk_83),.addr(wgt_fc2_addr),.dout(wgt_fc2_dout));
wgt_bram #(.DATA_WIDTH(DATA_WIDTH),.DEPTH(WGTFC3_DEPTH),.INIT_FILE("fc3.hex"))   u_wgt_fc3(.clk(clk_83),.addr(wgt_fc3_addr),.dout(wgt_fc3_dout));

// ─────────────────────────────────────────────────────────────
// Intermediate feature BRAMs
// ─────────────────────────────────────────────────────────────
wire [OFMAP1_AW-1:0]  ofmap1_wr_addr, ofmap1_rd_addr;
wire [DATA_WIDTH-1:0] ofmap1_wr_data, ofmap1_rd_data;
wire                  ofmap1_wr_en;

wire [OFMAP2_AW-1:0]  ofmap2_wr_addr, ofmap2_rd_addr;
wire [DATA_WIDTH-1:0] ofmap2_wr_data, ofmap2_rd_data;
wire                  ofmap2_wr_en;

ofmap_bram #(.DATA_WIDTH(DATA_WIDTH),.DEPTH(OFMAP1_DEPTH)) u_ofmap1 (
    .clk(clk_83),
    .wr_addr(ofmap1_wr_addr),.wr_data(ofmap1_wr_data),.wr_en(ofmap1_wr_en),
    .rd_addr(ofmap1_rd_addr),.rd_data(ofmap1_rd_data)
);

ofmap_bram #(.DATA_WIDTH(DATA_WIDTH),.DEPTH(OFMAP2_DEPTH)) u_ofmap2 (
    .clk(clk_83),
    .wr_addr(ofmap2_wr_addr),.wr_data(ofmap2_wr_data),.wr_en(ofmap2_wr_en),
    .rd_addr(ofmap2_rd_addr),.rd_data(ofmap2_rd_data)
);

// ─────────────────────────────────────────────────────────────
// Intermediate wires
// ─────────────────────────────────────────────────────────────
wire [DATA_WIDTH-1:0] fc1_out_data, fc2_out_data, fc3_out_data;
wire                  fc1_out_valid, fc2_out_valid, fc3_out_valid;
wire                  fc1_out_ready, fc2_out_ready, fc3_out_ready;
wire                  argm_ready;
wire [CLASS_W-1:0]    argm_class;
wire                  ovf_fc1, ovf_fc2, ovf_fc3;
wire                  ovf_c1 = 1'b0, ovf_c2 = 1'b0;

assign ovf_flag = ovf_c1 | ovf_c2 | ovf_fc1 | ovf_fc2 | ovf_fc3;

// ─────────────────────────────────────────────────────────────
// Pipeline FSM
//
// infer_done LATCHES high in ST_DONE and holds until the next
// start_pulse clears it.  This makes the LED stay visibly lit.
// ─────────────────────────────────────────────────────────────
localparam [3:0]
    ST_IDLE  = 4'd0, ST_CONV1 = 4'd1, ST_CONV2 = 4'd2,
    ST_FC1   = 4'd3, ST_FC2   = 4'd4, ST_FC3   = 4'd5,
    ST_ARGM  = 4'd6, ST_DONE  = 4'd7;

reg [3:0] pipe_state;
reg start_c1, start_c2, start_fc1, start_fc2, start_fc3, start_argm;
wire done_c1, done_c2, done_fc1, done_fc2, done_fc3, argm_done;

always @(posedge clk_83 or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        pipe_state  <= ST_IDLE;
        start_c1    <= 1'b0; start_c2   <= 1'b0;
        start_fc1   <= 1'b0; start_fc2  <= 1'b0;
        start_fc3   <= 1'b0; start_argm <= 1'b0;
        infer_done  <= 1'b0;
        class_out   <= '0;
    end else begin
        start_c1  <= 1'b0; start_c2  <= 1'b0;
        start_fc1 <= 1'b0; start_fc2 <= 1'b0;
        start_fc3 <= 1'b0; start_argm <= 1'b0;

        case (pipe_state)
            ST_IDLE: begin
                if (start_pulse) begin
                    infer_done <= 1'b0;
                    start_c1   <= 1'b1;
                    pipe_state <= ST_CONV1;
                end
            end

            ST_CONV1: if (done_c1)  begin start_c2   <= 1'b1; pipe_state <= ST_CONV2; end
            ST_CONV2: if (done_c2)  begin start_fc1  <= 1'b1; pipe_state <= ST_FC1;   end
            ST_FC1:   if (done_fc1) begin start_fc2  <= 1'b1; pipe_state <= ST_FC2;   end
            ST_FC2:   if (done_fc2) begin start_fc3  <= 1'b1; pipe_state <= ST_FC3;   end
            ST_FC3:   if (done_fc3) begin start_argm <= 1'b1; pipe_state <= ST_ARGM;  end

            ST_ARGM: begin
                if (argm_done) begin
                    class_out  <= argm_class;
                    infer_done <= 1'b1;   // LATCH - stays high until next start
                    pipe_state <= ST_DONE;
                end
            end

            ST_DONE: begin
                // infer_done stays HIGH here so the LED remains lit.
                // A new button press clears it and starts fresh.
                if (start_pulse) begin
                    infer_done <= 1'b0;
                    start_c1   <= 1'b1;
                    pipe_state <= ST_CONV1;
                end
            end

            default: pipe_state <= ST_IDLE;
        endcase
    end
end

// ─────────────────────────────────────────────────────────────
// Conv1 + ReLU + Pool1
// ─────────────────────────────────────────────────────────────
conv1_relu_pool1_ctrl #(
    .IN_CH(1),.OUT_CH(6),.IMG_W(101),.IMG_H(40),
    .PADDING(2),.KERNEL(5),.DATA_WIDTH(DATA_WIDTH)
) u_s1 (
    .clk(clk_83),.rst_n(sys_rst_n),.start(start_c1),.done(done_c1),
    .ifmap_addr(ifmap0_rd_addr),.ifmap_dout(ifmap0_rd_data),
    .wgt_addr(wgt1_addr),.wgt_dout(wgt1_dout),
    .ofmap1_wr_addr(ofmap1_wr_addr),.ofmap1_wr_data(ofmap1_wr_data),.ofmap1_wr_en(ofmap1_wr_en)
);

// ─────────────────────────────────────────────────────────────
// Conv2 + ReLU + Pool2
// ─────────────────────────────────────────────────────────────
conv2_relu_pool2_ctrl #(
    .IN_CH(6),.OUT_CH(16),.IMG_W(50),.IMG_H(20),
    .PADDING(0),.KERNEL(5),.DATA_WIDTH(DATA_WIDTH)
) u_s2 (
    .clk(clk_83),.rst_n(sys_rst_n),.start(start_c2),.done(done_c2),
    .ifmap_addr(ofmap1_rd_addr),.ifmap_dout(ofmap1_rd_data),
    .wgt_addr(wgt2_addr),.wgt_dout(wgt2_dout),
    .ofmap2_wr_addr(ofmap2_wr_addr),.ofmap2_wr_data(ofmap2_wr_data),.ofmap2_wr_en(ofmap2_wr_en)
);

// ─────────────────────────────────────────────────────────────
// Flatten (ofmap2 → FC1 stream)
// ─────────────────────────────────────────────────────────────
localparam FLAT_W = $clog2(OFMAP2_DEPTH);
reg  [FLAT_W-1:0] flat_addr;
wire              flat_valid;
wire              flat_ready;
reg               flat_running;

assign flat_valid     = flat_running;
assign ofmap2_rd_addr = flat_addr;

always @(posedge clk_83 or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        flat_addr    <= '0;
        flat_running <= 1'b0;
    end else if (start_fc1) begin
        flat_addr    <= '0;
        flat_running <= 1'b1;
    end else if (flat_running && flat_ready) begin
        if (flat_addr == OFMAP2_DEPTH[FLAT_W-1:0] - 1'b1) begin
            flat_running <= 1'b0;
            flat_addr    <= '0;
        end else
            flat_addr <= flat_addr + 1'b1;
    end
end

// ─────────────────────────────────────────────────────────────
// FC stages
// ─────────────────────────────────────────────────────────────
fc_stage_ctrl #(.IN_NODES(2944),.OUT_NODES(120),.DATA_WIDTH(DATA_WIDTH),.USE_RELU(1),.BUF_CNT_W(12)) u_fc1 (
    .clk(clk_83),.rst_n(sys_rst_n),.start(start_fc1),
    .wgt_addr(wgt_fc1_addr),.wgt_dout(wgt_fc1_dout),
    .in_data(ofmap2_rd_data),.in_valid(flat_valid),.in_ready(flat_ready),
    .out_data(fc1_out_data),.out_valid(fc1_out_valid),.out_ready(fc1_out_ready),
    .all_done(done_fc1),.ovf_flag(ovf_fc1)
);

fc_stage_ctrl #(.IN_NODES(120),.OUT_NODES(84),.DATA_WIDTH(DATA_WIDTH),.USE_RELU(1),.BUF_CNT_W(7)) u_fc2 (
    .clk(clk_83),.rst_n(sys_rst_n),.start(start_fc2),
    .wgt_addr(wgt_fc2_addr),.wgt_dout(wgt_fc2_dout),
    .in_data(fc1_out_data),.in_valid(fc1_out_valid),.in_ready(fc1_out_ready),
    .out_data(fc2_out_data),.out_valid(fc2_out_valid),.out_ready(fc2_out_ready),
    .all_done(done_fc2),.ovf_flag(ovf_fc2)
);

fc_stage_ctrl #(.IN_NODES(84),.OUT_NODES(31),.DATA_WIDTH(DATA_WIDTH),.USE_RELU(0),.BUF_CNT_W(7)) u_fc3 (
    .clk(clk_83),.rst_n(sys_rst_n),.start(start_fc3),
    .wgt_addr(wgt_fc3_addr),.wgt_dout(wgt_fc3_dout),
    .in_data(fc2_out_data),.in_valid(fc2_out_valid),.in_ready(fc2_out_ready),
    .out_data(fc3_out_data),.out_valid(fc3_out_valid),.out_ready(fc3_out_ready),
    .all_done(done_fc3),.ovf_flag(ovf_fc3)
);

// ─────────────────────────────────────────────────────────────
// Argmax
// ─────────────────────────────────────────────────────────────
argmax #(.NUM_CLASSES(NUM_CLASSES),.DATA_WIDTH(DATA_WIDTH)) u_argmax (
    .clk(clk_83),.rst_n(sys_rst_n),.start(start_argm),
    .in_data(fc3_out_data),.in_valid(fc3_out_valid),.in_ready(argm_ready),
    .class_idx(argm_class),.done(argm_done)
);

assign fc3_out_ready = argm_ready;

assign LED[4:0]   = class_out;      // Result
assign LED[10]    = infer_done;     // SUCCESS LIGHT
assign LED[14]    = ovf_flag;       // ERROR LIGHT
assign LED[15]    = pipe_state[0];         // CLOCK OK

// Debugging Row
assign LED[13:11] = pipe_state[2:0]; // Shows the state (IDLE=0, CONV1=1, etc.)
assign LED[9]     = infer_start;    // Lights up when you press BTNC
assign LED[8]     = rst_n;          // Should be ON when NOT pressing red button
assign LED[7]     = sys_rst_n;      // MUST BE ON for the engine to work!
assign LED[6:5]   = 2'b0;
  // Clock status


endmodule
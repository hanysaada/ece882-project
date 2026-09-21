// ============================================================================
// dot3.sv — 3-lane dot product: ax*bx + ay*by + az*bz
// ----------------------------------------------------------------------------
// Interface contract
//   LATENCY            : 9 cycles  (3 mul + 3 add + 3 add = one 2-level tree)
//   INITIATION INTERVAL: 1  -- a new vector pair every cycle
//   THROUGHPUT         : 1 dot product/cycle when full
//   TARGET FREQUENCY   : 500 MHz  => 5e8 dot products/second
//
// Structure: three multipliers in PARALLEL, feeding a 2-level adder tree.
//
//   ax --\                                    (level 1)      (level 2)
//         mul0 --> p0 --\
//   bx --/               add_01 --> s01 --\
//   ay --\               /                 \
//         mul1 --> p1 --/                   add_final --> y
//   by --/                                 /
//   az --\                                /
//         mul2 --> p2 -- (delayed 3cy) --/
//   bz --/
//
// THE TREE SHAPE IS PART OF THE SPEC, NOT AN IMPLEMENTATION DETAIL.
// IEEE-754 addition is not associative: (p0+p1)+p2 and p0+(p1+p2) can differ in
// the last bit. This module commits to ((p0+p1)+p2), and hw/golden/model.py
// computes the same order, so the testbench can demand bit-exact equality
// rather than "close enough". If the two ever disagree the testbench fails
// loudly, which is the point.
//
// p2 must be DELAYED by the latency of the level-1 adder so it arrives at the
// level-2 adder in the same cycle as s01. Forgetting this shift register is the
// classic pipeline-balancing bug: the design would compute p0+p1 from cycle N
// and p2 from cycle N+3, silently mixing two different inputs.
//
// Why this is the right primitive for both benchmarks:
//   nbody     d2 = dot3(d, d)                      (squared distance)
//   raytrace  v  = dot3(cp, rv), cc = dot3(cp, cp) (intersection test)
//             also Vector.dot, and magnitude via sqrt(dot3(v,v))
// ============================================================================
`default_nettype none

module dot3 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        v_in,
    input  wire [31:0] ax, ay, az,
    input  wire [31:0] bx, by, bz,
    output wire        v_out,
    output wire [31:0] y
);

    localparam int MUL_LAT = 3;
    localparam int ADD_LAT = 3;
    localparam int LATENCY = MUL_LAT + 2*ADD_LAT;   // = 9

    // ---------------- three parallel multipliers -----------------------------
    wire        vm0, vm1, vm2;
    wire [31:0] p0, p1, p2;

    fp32_mul u_mul0 (.clk(clk), .rst_n(rst_n), .v_in(v_in),
                     .a(ax), .b(bx), .v_out(vm0), .y(p0));
    fp32_mul u_mul1 (.clk(clk), .rst_n(rst_n), .v_in(v_in),
                     .a(ay), .b(by), .v_out(vm1), .y(p1));
    fp32_mul u_mul2 (.clk(clk), .rst_n(rst_n), .v_in(v_in),
                     .a(az), .b(bz), .v_out(vm2), .y(p2));

    // ---------------- adder tree, level 1: p0 + p1 --------------------------
    wire        va01;
    wire [31:0] s01;

    fp32_add u_add01 (.clk(clk), .rst_n(rst_n), .v_in(vm0),
                      .a(p0), .b(p1), .v_out(va01), .y(s01));

    // ---------------- delay p2 to match the level-1 adder -------------------
    // p2 is valid ADD_LAT cycles before s01 is, so it must be held.
    reg [31:0] p2_dly [0:ADD_LAT-1];
    integer i;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < ADD_LAT; i = i + 1) p2_dly[i] <= 32'd0;
        end else begin
            p2_dly[0] <= p2;
            for (i = 1; i < ADD_LAT; i = i + 1) p2_dly[i] <= p2_dly[i-1];
        end
    end
    wire [31:0] p2_aligned = p2_dly[ADD_LAT-1];

    // ---------------- adder tree, level 2: s01 + p2 -------------------------
    fp32_add u_add_final (.clk(clk), .rst_n(rst_n), .v_in(va01),
                          .a(s01), .b(p2_aligned), .v_out(v_out), .y(y));

endmodule

`default_nettype wire

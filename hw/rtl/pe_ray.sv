// ============================================================================
// pe_ray.sv — ray/sphere intersection processing element
// ----------------------------------------------------------------------------
// The SECOND entry point onto the same dot3 + rsqrt datapath. Computes
// raytrace's Sphere.intersectionTime, which after the Phase 3 software
// optimization reads:
//
//     cx,cy,cz = centre - ray.point            (formed by the caller)
//     v        = cp . rv                       (dot3)
//     cc       = cp . cp                       (dot3)
//     disc     = radius2 - (cc - v*v)
//     miss if disc < 0
//     t        = v - sqrt(disc)                 (sqrt = disc * rsqrt(disc))
//
// WHY THIS MATTERS FOR THE PROJECT'S ARGUMENT
// Phase 2 profiling showed raytrace is NOT math-bound: no sqrt appears above the
// 0.5% cutoff, and the cost is object allocation and method calls
// (subtype_dealloc 3.11%, _PyObject_Malloc 1.95%, slot_tp_init 1.65%). So the
// accelerator is not justified for raytrace by "a faster sqrt" -- pitched that
// way its Amdahl f would be ~5-10%, capping total speedup near 1.11x.
//
// It is justified because a batched call replaces the WHOLE Python vector-math
// layer for the intersection test: the intermediate Vector allocation
// (__sub__:115, 15.6% of samples), the two dot() method calls (dot:53 10.3%,
// dot:52 3.5%), and the attribute lookups around them all disappear into one
// descriptor. Those costs are measured, so the claim is quantified.
//
// It also mirrors real silicon: NVIDIA RT cores exist precisely to accelerate
// ray/primitive intersection.
//
// Interface contract
//   LATENCY            : 49 cycles (identical to pe_pair, by construction)
//                        9 (dot3) + 3 (v*v) + 3 (cc-v2) + 3 (r2-..) + 25 (rsqrt)
//                        + 3 (disc*rsqrt) + 3 (v - sqrt) = 49
//   INITIATION INTERVAL: 1  -- one ray/sphere test per cycle
//   THROUGHPUT         : 5e8 intersection tests/s at 500 MHz
//   TARGET FREQUENCY   : 500 MHz
//
// `hit` is the answer to "did the ray meet the sphere". When hit is 0, `t` is
// meaningless and MUST be ignored -- rsqrt of a negative number is not defined
// and the unit flags it internally rather than producing a plausible wrong
// number. The Python original returns None in that case; the hardware equivalent
// is a validity bit alongside the datum.
//
// The ray direction is assumed NORMALISED, exactly as the Python original assumes
// (Ray.__init__ calls vector.normalized()). That assumption is what allows the
// quadratic's leading coefficient to be 1 and is why only one sqrt is needed.
// ============================================================================
`default_nettype none

module pe_ray (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        v_in,
    input  wire [31:0] cx, cy, cz,      // sphere.centre - ray.point
    input  wire [31:0] rvx, rvy, rvz,   // ray direction, normalised
    input  wire [31:0] radius2,         // sphere radius squared (precomputed,
                                        // matching the software optimization)
    output wire        v_out,
    output wire [31:0] t,               // intersection distance, valid iff hit
    output wire        hit,             // discriminant >= 0
    output wire        err              // rsqrt saw a bad input
);

    localparam int MUL_LAT   = 3;
    localparam int ADD_LAT   = 3;
    localparam int DOT3_LAT  = 9;
    localparam int RSQRT_LAT = 25;

    localparam int L_DOT  = DOT3_LAT;                 //  9  v and cc ready
    localparam int L_V2   = L_DOT + MUL_LAT;          // 12  v*v
    localparam int L_SUB1 = L_V2  + ADD_LAT;          // 15  cc - v*v
    localparam int L_DISC = L_SUB1 + ADD_LAT;         // 18  radius2 - (...)
    localparam int L_RS   = L_DISC + RSQRT_LAT;       // 43  rsqrt(disc)
    localparam int L_SQRT = L_RS  + MUL_LAT;          // 46  disc * rsqrt(disc)
    localparam int LATENCY = L_SQRT + ADD_LAT;        // 49  v - sqrt(disc)

    // ---------------- two dot3 units, in parallel ---------------------------
    // Both consume cp, so this is where the "one datapath, two entry points"
    // claim is cashed: the same three-multiplier/adder-tree structure as nbody.
    wire        v_dot;
    wire [31:0] v_dp, cc;
    dot3 u_dot_v (.clk(clk), .rst_n(rst_n), .v_in(v_in),
                  .ax(cx), .ay(cy), .az(cz),
                  .bx(rvx), .by(rvy), .bz(rvz),
                  .v_out(v_dot), .y(v_dp));
    dot3 u_dot_c (.clk(clk), .rst_n(rst_n), .v_in(v_in),
                  .ax(cx), .ay(cy), .az(cz),
                  .bx(cx), .by(cy), .bz(cz),
                  .v_out(), .y(cc));

    // ---------------- v2 = v*v ----------------------------------------------
    wire        v_v2;
    wire [31:0] v2;
    fp32_mul u_v2 (.clk(clk), .rst_n(rst_n), .v_in(v_dot),
                   .a(v_dp), .b(v_dp), .v_out(v_v2), .y(v2));

    // ---------------- s1 = cc - v2 ------------------------------------------
    wire [31:0] cc_d;
    delay_line #(.WIDTH(32), .DEPTH(MUL_LAT)) u_dl_cc
        (.clk(clk), .rst_n(rst_n), .d(cc), .q(cc_d));

    wire [31:0] neg_v2 = {~v2[31], v2[30:0]};      // subtraction is free
    wire        v_s1;
    wire [31:0] s1;
    fp32_add u_s1 (.clk(clk), .rst_n(rst_n), .v_in(v_v2),
                   .a(cc_d), .b(neg_v2), .v_out(v_s1), .y(s1));

    // ---------------- disc = radius2 - s1 -----------------------------------
    wire [31:0] r2_d;
    delay_line #(.WIDTH(32), .DEPTH(L_SUB1)) u_dl_r2
        (.clk(clk), .rst_n(rst_n), .d(radius2), .q(r2_d));

    wire [31:0] neg_s1 = {~s1[31], s1[30:0]};
    wire        v_disc;
    wire [31:0] disc;
    fp32_add u_disc (.clk(clk), .rst_n(rst_n), .v_in(v_s1),
                     .a(r2_d), .b(neg_s1), .v_out(v_disc), .y(disc));

    // A miss is disc < 0, i.e. the sign bit set (and not negative zero, which is
    // still a grazing hit). Checking the sign bit is free -- no comparator.
    wire disc_neg = disc[31] & (|disc[30:0]);

    // ---------------- rsqrt(disc), then sqrt = disc * rsqrt ------------------
    // rsqrt would flag a negative input, so feed it a harmless 1.0 on a miss and
    // carry the miss flag alongside. That keeps `err` meaningful: it then only
    // fires on genuinely unexpected data, not on the ordinary miss case which the
    // caller already knows how to handle.
    wire [31:0] rs_in = disc_neg ? 32'h3F800000 : disc;

    wire        v_rs, rs_err;
    wire [31:0] rs;
    rsqrt #(.LUT_BITS(6), .NR_ITERS(2)) u_rsqrt (
        .clk(clk), .rst_n(rst_n), .v_in(v_disc), .x(rs_in),
        .v_out(v_rs), .y(rs), .err(rs_err)
    );

    wire [31:0] disc_d;
    delay_line #(.WIDTH(32), .DEPTH(RSQRT_LAT)) u_dl_disc
        (.clk(clk), .rst_n(rst_n), .d(disc), .q(disc_d));

    wire        v_sq;
    wire [31:0] sq;                                  // sqrt(disc)
    fp32_mul u_sq (.clk(clk), .rst_n(rst_n), .v_in(v_rs),
                   .a(disc_d), .b(rs), .v_out(v_sq), .y(sq));

    // ---------------- t = v - sqrt(disc) ------------------------------------
    wire [31:0] v_d;
    delay_line #(.WIDTH(32), .DEPTH(L_SQRT - L_DOT)) u_dl_v
        (.clk(clk), .rst_n(rst_n), .d(v_dp), .q(v_d));

    wire [31:0] neg_sq = {~sq[31], sq[30:0]};
    fp32_add u_t (.clk(clk), .rst_n(rst_n), .v_in(v_sq),
                  .a(v_d), .b(neg_sq), .v_out(v_out), .y(t));

    // ---------------- flags, aligned to the output --------------------------
    wire hit_int;
    delay_line #(.WIDTH(1), .DEPTH(LATENCY - L_DISC)) u_dl_hit
        (.clk(clk), .rst_n(rst_n), .d(~disc_neg), .q(hit_int));
    assign hit = hit_int;

    delay_line #(.WIDTH(1), .DEPTH(LATENCY - L_RS)) u_dl_err
        (.clk(clk), .rst_n(rst_n), .d(rs_err), .q(err));

endmodule

`default_nettype wire

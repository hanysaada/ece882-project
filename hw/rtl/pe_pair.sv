// ============================================================================
// pe_pair.sv — nbody pair-interaction processing element
// ----------------------------------------------------------------------------
// Computes one body-pair gravitational interaction, exactly as the optimized
// Python does, and returns the six velocity deltas ready to be accumulated.
//
//   d2   = dx^2 + dy^2 + dz^2                    (dot3)
//   r    = 1/sqrt(d2)                            (rsqrt)
//   mag  = dt * r^3        == dt * d2^(-1.5)     (the identity that lets ONE
//                                                 rsqrt unit serve nbody)
//   b1m  = m1 * mag ,  b2m = m2 * mag
//   body1 velocity -= (dx,dy,dz) * b2m
//   body2 velocity += (dx,dy,dz) * b1m
//
// Interface contract
//   LATENCY            : 49 cycles
//                        9 (dot3) + 25 (rsqrt) + 3 (r*r) + 3 (*r) + 3 (*dt)
//                        + 3 (*mass) + 3 (*delta) = 49
//   INITIATION INTERVAL: 1  -- a new pair every cycle
//   THROUGHPUT         : 1 pair/cycle = 5e8 pairs/s at 500 MHz
//   TARGET FREQUENCY   : 500 MHz
//
// The unit returns DELTAS rather than updated velocities. That is deliberate:
// a body appears in several pairs, so the accumulation must happen where all of
// a body's pairs are visible. Doing it here would need a read-modify-write on
// shared state and would serialise the pipeline. accel_top.sv accumulates.
//
// Note the sign convention: dv1 is what to SUBTRACT from body 1 and dv2 what to
// ADD to body 2, matching the Python source, so no negation logic is needed.
// ============================================================================
`default_nettype none

module pe_pair (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        v_in,
    input  wire [31:0] dx, dy, dz,     // body1.pos - body2.pos
    input  wire [31:0] dt,             // timestep
    input  wire [31:0] m1, m2,         // the two masses
    output wire        v_out,
    output wire [31:0] dv1x, dv1y, dv1z,   // subtract from body 1
    output wire [31:0] dv2x, dv2y, dv2z,   // add to body 2
    output wire [31:0] mag_out,            // dt * d2^-1.5, exposed for debug
    output wire        err                 // rsqrt saw a bad input (d2 <= 0)
);

    localparam int MUL_LAT   = 3;
    localparam int DOT3_LAT  = 9;
    localparam int RSQRT_LAT = 25;
    // cumulative depths, used to size the delay lines
    localparam int L_D2   = DOT3_LAT;                      //  9
    localparam int L_R    = L_D2 + RSQRT_LAT;              // 34
    localparam int L_R2   = L_R  + MUL_LAT;                // 37
    localparam int L_R3   = L_R2 + MUL_LAT;                // 40
    localparam int L_MAG  = L_R3 + MUL_LAT;                // 43
    localparam int L_BM   = L_MAG + MUL_LAT;               // 46
    localparam int LATENCY = L_BM + MUL_LAT;               // 49

    // ---------------- d2 = dot3(d, d) ---------------------------------------
    wire        v_d2;
    wire [31:0] d2;
    dot3 u_dot3 (.clk(clk), .rst_n(rst_n), .v_in(v_in),
                 .ax(dx), .ay(dy), .az(dz),
                 .bx(dx), .by(dy), .bz(dz),
                 .v_out(v_d2), .y(d2));

    // ---------------- r = rsqrt(d2) -----------------------------------------
    wire        v_r, rsqrt_err;
    wire [31:0] r;
    rsqrt #(.LUT_BITS(6), .NR_ITERS(2)) u_rsqrt (
        .clk(clk), .rst_n(rst_n), .v_in(v_d2), .x(d2),
        .v_out(v_r), .y(r), .err(rsqrt_err)
    );

    // ---------------- r3 = r*r*r --------------------------------------------
    wire        v_r2;
    wire [31:0] r2;
    fp32_mul u_rr (.clk(clk), .rst_n(rst_n), .v_in(v_r),
                   .a(r), .b(r), .v_out(v_r2), .y(r2));

    // r must be held while r*r is computed.
    wire [31:0] r_d;
    delay_line #(.WIDTH(32), .DEPTH(MUL_LAT)) u_dl_r
        (.clk(clk), .rst_n(rst_n), .d(r), .q(r_d));

    wire        v_r3;
    wire [31:0] r3;
    fp32_mul u_r2r (.clk(clk), .rst_n(rst_n), .v_in(v_r2),
                    .a(r2), .b(r_d), .v_out(v_r3), .y(r3));

    // ---------------- mag = dt * r3 -----------------------------------------
    wire [31:0] dt_d;
    delay_line #(.WIDTH(32), .DEPTH(L_R3)) u_dl_dt
        (.clk(clk), .rst_n(rst_n), .d(dt), .q(dt_d));

    wire        v_mag;
    wire [31:0] mag;
    fp32_mul u_mag (.clk(clk), .rst_n(rst_n), .v_in(v_r3),
                    .a(dt_d), .b(r3), .v_out(v_mag), .y(mag));

    // ---------------- b1m = m1*mag , b2m = m2*mag ---------------------------
    wire [31:0] m1_d, m2_d;
    delay_line #(.WIDTH(32), .DEPTH(L_MAG)) u_dl_m1
        (.clk(clk), .rst_n(rst_n), .d(m1), .q(m1_d));
    delay_line #(.WIDTH(32), .DEPTH(L_MAG)) u_dl_m2
        (.clk(clk), .rst_n(rst_n), .d(m2), .q(m2_d));

    wire        v_b1m, v_b2m;
    wire [31:0] b1m, b2m;
    fp32_mul u_b1m (.clk(clk), .rst_n(rst_n), .v_in(v_mag),
                    .a(m1_d), .b(mag), .v_out(v_b1m), .y(b1m));
    fp32_mul u_b2m (.clk(clk), .rst_n(rst_n), .v_in(v_mag),
                    .a(m2_d), .b(mag), .v_out(v_b2m), .y(b2m));

    // ---------------- six delta multiplies ----------------------------------
    // dx,dy,dz have to survive all the way to here: 46 cycles.
    wire [31:0] dx_d, dy_d, dz_d;
    delay_line #(.WIDTH(32), .DEPTH(L_BM)) u_dl_dx
        (.clk(clk), .rst_n(rst_n), .d(dx), .q(dx_d));
    delay_line #(.WIDTH(32), .DEPTH(L_BM)) u_dl_dy
        (.clk(clk), .rst_n(rst_n), .d(dy), .q(dy_d));
    delay_line #(.WIDTH(32), .DEPTH(L_BM)) u_dl_dz
        (.clk(clk), .rst_n(rst_n), .d(dz), .q(dz_d));

    // body 1 gets -(d * b2m), body 2 gets +(d * b1m)
    wire v_o1x, v_o1y, v_o1z, v_o2x, v_o2y, v_o2z;
    fp32_mul u_o1x (.clk(clk), .rst_n(rst_n), .v_in(v_b2m),
                    .a(dx_d), .b(b2m), .v_out(v_o1x), .y(dv1x));
    fp32_mul u_o1y (.clk(clk), .rst_n(rst_n), .v_in(v_b2m),
                    .a(dy_d), .b(b2m), .v_out(v_o1y), .y(dv1y));
    fp32_mul u_o1z (.clk(clk), .rst_n(rst_n), .v_in(v_b2m),
                    .a(dz_d), .b(b2m), .v_out(v_o1z), .y(dv1z));
    fp32_mul u_o2x (.clk(clk), .rst_n(rst_n), .v_in(v_b1m),
                    .a(dx_d), .b(b1m), .v_out(v_o2x), .y(dv2x));
    fp32_mul u_o2y (.clk(clk), .rst_n(rst_n), .v_in(v_b1m),
                    .a(dy_d), .b(b1m), .v_out(v_o2y), .y(dv2y));
    fp32_mul u_o2z (.clk(clk), .rst_n(rst_n), .v_in(v_b1m),
                    .a(dz_d), .b(b1m), .v_out(v_o2z), .y(dv2z));

    assign v_out = v_o1x;          // all six finish in the same cycle

    // mag is produced 6 cycles before the outputs; align it for observability.
    delay_line #(.WIDTH(32), .DEPTH(2*MUL_LAT)) u_dl_mag
        (.clk(clk), .rst_n(rst_n), .d(mag), .q(mag_out));

    // Carry the rsqrt error flag to the output boundary.
    delay_line #(.WIDTH(1), .DEPTH(LATENCY - L_R)) u_dl_err
        (.clk(clk), .rst_n(rst_n), .d(rsqrt_err), .q(err));

endmodule

`default_nettype wire

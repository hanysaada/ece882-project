// ============================================================================
// fp32_mul.sv — pipelined IEEE-754 binary32 multiplier
// ----------------------------------------------------------------------------
// Interface contract
//   LATENCY            : 3 cycles (registered at each stage boundary)
//   INITIATION INTERVAL: 1 (a new pair may be presented every cycle)
//   THROUGHPUT         : 1 result/cycle once the pipe is full
//   TARGET FREQUENCY   : 500 MHz (the 24x24 partial-product array in S1 is the
//                        critical path; see hw/README.md for the reasoning)
//
// Ports are pure dataflow: no handshake, no backpressure. The unit accepts a
// new input every cycle unconditionally, and `v_out` is `v_in` delayed by the
// pipeline depth. That is deliberate -- this is the systolic style from the
// course's Lecture 4: no control circuitry, timed only by the clock. Flow
// control lives once, in accel_top.sv, rather than in every leaf unit.
//
// Rounding: round-to-nearest-even (RNE), IEEE-754's default mode.
//
// Subnormal inputs and outputs are FLUSHED TO ZERO. This is a documented
// deviation from full IEEE-754, taken because subnormal handling costs a
// leading-zero counter plus a variable shifter in the critical path for no
// benefit here: nbody's squared distances and raytrace's dot products live in a
// normal range (roughly 1e-6..1e6). The golden model does not flush, so the
// testbench avoids subnormal stimulus; if it ever produced one, the mismatch
// would be caught rather than hidden.
// ============================================================================
`default_nettype none

module fp32_mul (
    input  wire        clk,
    input  wire        rst_n,        // synchronous, active low
    input  wire        v_in,         // input valid
    input  wire [31:0] a,            // binary32
    input  wire [31:0] b,            // binary32
    output wire        v_out,        // valid, = v_in delayed by LATENCY
    output wire [31:0] y             // binary32 product
);

    localparam int LATENCY = 3;

    // ---------------- field extraction (combinational, stage 0) -------------
    wire        a_sgn = a[31];
    wire [7:0]  a_exp = a[30:23];
    wire [22:0] a_man = a[22:0];
    wire        b_sgn = b[31];
    wire [7:0]  b_exp = b[30:23];
    wire [22:0] b_man = b[22:0];

    wire a_is_zero = (a_exp == 8'h00);          // incl. flushed subnormals
    wire b_is_zero = (b_exp == 8'h00);
    wire a_is_inf  = (a_exp == 8'hFF) && (a_man == 23'd0);
    wire b_is_inf  = (b_exp == 8'hFF) && (b_man == 23'd0);
    wire a_is_nan  = (a_exp == 8'hFF) && (a_man != 23'd0);
    wire b_is_nan  = (b_exp == 8'hFF) && (b_man != 23'd0);

    // 0 * inf is the only invalid case for multiply -> quiet NaN.
    wire special_nan = a_is_nan | b_is_nan |
                       (a_is_zero & b_is_inf) | (b_is_zero & a_is_inf);
    wire special_inf = (a_is_inf | b_is_inf) & ~special_nan;
    wire special_zro = (a_is_zero | b_is_zero) & ~special_nan & ~special_inf;

    // Implicit leading 1 for normal operands.
    wire [23:0] a_sig = {~a_is_zero, a_man};
    wire [23:0] b_sig = {~b_is_zero, b_man};

    // ---------------- S1: sign, exponent sum, 24x24 product -----------------
    // This multiply is the critical path and is what sets f_max. A synthesis
    // tool will map it to DSP blocks on an FPGA or a Booth/Wallace array in an
    // ASIC flow; either way it is the reason the unit is pipelined at all.
    reg         s1_v, s1_sgn, s1_nan, s1_inf, s1_zro;
    reg  signed [9:0]  s1_exp;      // biased sum minus one bias, room for over/underflow
    reg  [47:0] s1_prod;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s1_v <= 1'b0;
        end else begin
            s1_v    <= v_in;
            s1_sgn  <= a_sgn ^ b_sgn;
            s1_nan  <= special_nan;
            s1_inf  <= special_inf;
            s1_zro  <= special_zro;
            // exponents are biased by 127 each; the sum is biased by 254, so
            // subtract one bias to get back to a single-biased exponent.
            s1_exp  <= $signed({2'b00, a_exp}) + $signed({2'b00, b_exp}) - 10'sd127;
            s1_prod <= a_sig * b_sig;          // 24x24 -> 48 bits
        end
    end

    // ---------------- S2: normalise and round -------------------------------
    // The product of two values in [1,2) lies in [1,4), so bit 47 tells us
    // whether a 1-bit right shift (and an exponent increment) is needed.
    wire        s2_shift = s1_prod[47];
    wire [47:0] s2_align = s2_shift ? s1_prod : (s1_prod << 1);
    // s2_align[47] is now the implicit 1. Significand = [46:24], guard/round/
    // sticky come from the bits below.
    wire [22:0] s2_man_pre = s2_align[46:24];
    wire        s2_guard   = s2_align[23];
    wire        s2_round   = s2_align[22];
    wire        s2_sticky  = |s2_align[21:0];
    // Round to nearest, ties to even: round up if guard & (round | sticky |
    // lsb-of-kept). This is the standard RNE condition.
    wire        s2_round_up = s2_guard & (s2_round | s2_sticky | s2_man_pre[0]);

    reg         s2_v, s2_sgn, s2_nan, s2_inf, s2_zro;
    reg  signed [9:0]  s2_exp;
    reg  [23:0] s2_man;             // 24 bits: may carry out of 23 on round-up

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s2_v <= 1'b0;
        end else begin
            s2_v   <= s1_v;
            s2_sgn <= s1_sgn;
            s2_nan <= s1_nan;
            s2_inf <= s1_inf;
            s2_zro <= s1_zro;
            s2_exp <= s1_exp + (s2_shift ? 10'sd1 : 10'sd0);
            s2_man <= {1'b0, s2_man_pre} + (s2_round_up ? 24'd1 : 24'd0);
        end
    end

    // ---------------- S3: post-round fixup, overflow/underflow, pack --------
    // A round-up can carry out of the 23-bit FRACTION into bit 23. Note s2_man
    // holds the fraction only -- the leading 1 is implicit -- so a carry means
    // the significand went from 1.111...1 to exactly 2.0.
    //
    // Representing 2.0 as 1.0 x 2^(e+1) means the new fraction is ZERO and the
    // exponent increments. Writing `s2_man[23:1]` here instead was a real bug:
    // for s2_man = 0x800000 it yields 0x400000, i.e. a significand of 1.5. It
    // survived 511 of 512 random test vectors and was only exposed by a product
    // whose fraction was all ones (0.1181 * 8.4649 = 0.99999...), which is
    // exactly the one input pattern that can carry. Rounding edge cases do not
    // show up in random stimulus at useful rates; they have to be reasoned about.
    wire        s3_carry = s2_man[23];
    wire [22:0] s3_man   = s3_carry ? 23'd0 : s2_man[22:0];
    wire signed [9:0] s3_exp = s2_exp + (s3_carry ? 10'sd1 : 10'sd0);

    wire s3_ovf = (s3_exp >= 10'sd255);
    wire s3_unf = (s3_exp <= 10'sd0);

    reg  [31:0] y_r;
    reg         v_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            v_r <= 1'b0;
            y_r <= 32'd0;
        end else begin
            v_r <= s2_v;
            if (s2_nan)       y_r <= {1'b0, 8'hFF, 23'h400000};   // quiet NaN
            else if (s2_inf)  y_r <= {s2_sgn, 8'hFF, 23'd0};
            else if (s2_zro)  y_r <= {s2_sgn, 8'h00, 23'd0};
            else if (s3_ovf)  y_r <= {s2_sgn, 8'hFF, 23'd0};      // -> inf
            else if (s3_unf)  y_r <= {s2_sgn, 8'h00, 23'd0};      // flush to zero
            else              y_r <= {s2_sgn, s3_exp[7:0], s3_man};
        end
    end

    assign y     = y_r;
    assign v_out = v_r;

endmodule

`default_nettype wire

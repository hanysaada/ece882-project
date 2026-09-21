// ============================================================================
// fp32_add.sv — pipelined IEEE-754 binary32 adder
// ----------------------------------------------------------------------------
// Interface contract
//   LATENCY            : 3 cycles
//   INITIATION INTERVAL: 1
//   TARGET FREQUENCY   : 500 MHz
//
// Same dataflow style as fp32_mul: no handshake, `v_out` is `v_in` delayed by
// LATENCY. Rounding is round-to-nearest-even. Subnormals are flushed to zero
// (see fp32_mul.sv for why).
//
// Floating-point addition is harder than multiplication, and the reason is worth
// knowing: the operands must first be brought to a COMMON exponent, which needs
// a variable right shift of up to 24 places, and after a subtraction of nearly
// equal values the result can have many leading zeros, which needs a
// leading-zero count and a variable LEFT shift to renormalise. That is two
// variable shifters and a priority encoder, versus the multiplier's single
// fixed-size array. In an ASIC the adder is often the deeper of the two.
//
// This implementation keeps 3 stages:
//   S1  compare/swap, exponent difference, align the smaller operand
//   S2  add or subtract the aligned significands
//   S3  leading-zero normalise, round, pack
// ============================================================================
`default_nettype none

module fp32_add (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        v_in,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire        v_out,
    output wire [31:0] y
);

    localparam int LATENCY = 3;

    // ---------------- field extraction --------------------------------------
    wire        a_sgn = a[31];
    wire [7:0]  a_exp = a[30:23];
    wire [22:0] a_man = a[22:0];
    wire        b_sgn = b[31];
    wire [7:0]  b_exp = b[30:23];
    wire [22:0] b_man = b[22:0];

    wire a_is_zero = (a_exp == 8'h00);
    wire b_is_zero = (b_exp == 8'h00);
    wire a_is_inf  = (a_exp == 8'hFF) && (a_man == 23'd0);
    wire b_is_inf  = (b_exp == 8'hFF) && (b_man == 23'd0);
    wire a_is_nan  = (a_exp == 8'hFF) && (a_man != 23'd0);
    wire b_is_nan  = (b_exp == 8'hFF) && (b_man != 23'd0);

    // inf + (-inf) is invalid -> NaN. Everything else with an inf gives inf.
    wire special_nan = a_is_nan | b_is_nan |
                       (a_is_inf & b_is_inf & (a_sgn ^ b_sgn));
    wire special_inf = (a_is_inf | b_is_inf) & ~special_nan;
    wire inf_sgn     = a_is_inf ? a_sgn : b_sgn;

    wire [23:0] a_sig = {~a_is_zero, a_man};
    wire [23:0] b_sig = {~b_is_zero, b_man};

    // ---------------- S1: order operands and align --------------------------
    // Put the larger-magnitude operand in `big`. Comparing {exp,man} as one
    // unsigned number works because IEEE-754 is designed so that, for a fixed
    // sign, the bit pattern orders monotonically with magnitude.
    wire a_ge = ({a_exp, a_man} >= {b_exp, b_man});

    wire        big_sgn = a_ge ? a_sgn : b_sgn;
    wire [7:0]  big_exp = a_ge ? a_exp : b_exp;
    wire [23:0] big_sig = a_ge ? a_sig : b_sig;
    wire        sml_sgn = a_ge ? b_sgn : a_sgn;
    wire [7:0]  sml_exp = a_ge ? b_exp : a_exp;
    wire [23:0] sml_sig = a_ge ? b_sig : a_sig;

    wire [7:0]  exp_diff = big_exp - sml_exp;
    // Cap the shift: beyond 26 places the small operand can only contribute a
    // sticky bit, so clamping avoids a needlessly wide shifter.
    wire [4:0]  shamt = (exp_diff > 8'd26) ? 5'd26 : exp_diff[4:0];

    // Extend with 3 guard bits (guard, round, sticky) before shifting so the
    // rounding information survives alignment.
    wire [26:0] sml_ext  = {sml_sig, 3'b000};
    wire [26:0] sml_algn = sml_ext >> shamt;
    // Anything shifted out entirely must still set sticky, or we would round
    // as if the small operand were exactly zero.
    wire        sml_lost = |(sml_ext & ((27'd1 << shamt) - 27'd1));

    reg         s1_v, s1_sgn, s1_sub, s1_nan, s1_inf, s1_isgn, s1_bothzero;
    reg  [7:0]  s1_exp;
    reg  [26:0] s1_big, s1_sml;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s1_v <= 1'b0;
        end else begin
            s1_v        <= v_in;
            s1_sgn      <= big_sgn;                 // result takes the larger's sign
            s1_sub      <= big_sgn ^ sml_sgn;       // opposite signs -> subtract
            s1_nan      <= special_nan;
            s1_inf      <= special_inf;
            s1_isgn     <= inf_sgn;
            s1_bothzero <= a_is_zero & b_is_zero;
            s1_exp      <= big_exp;
            s1_big      <= {big_sig, 3'b000};
            s1_sml      <= sml_algn | {26'd0, sml_lost};
        end
    end

    // ---------------- S2: add or subtract -----------------------------------
    reg         s2_v, s2_sgn, s2_nan, s2_inf, s2_isgn, s2_bothzero;
    reg  [7:0]  s2_exp;
    reg  [27:0] s2_sum;            // one extra bit for add carry-out

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s2_v <= 1'b0;
        end else begin
            s2_v        <= s1_v;
            s2_sgn      <= s1_sgn;
            s2_nan      <= s1_nan;
            s2_inf      <= s1_inf;
            s2_isgn     <= s1_isgn;
            s2_bothzero <= s1_bothzero;
            s2_exp      <= s1_exp;
            s2_sum      <= s1_sub ? ({1'b0, s1_big} - {1'b0, s1_sml})
                                  : ({1'b0, s1_big} + {1'b0, s1_sml});
        end
    end

    // ---------------- S3: normalise, round, pack ----------------------------
    // Three cases:
    //   carry out (bit 27 set)  -> shift right 1, exponent +1
    //   already normal (bit 26) -> no shift
    //   leading zeros           -> shift left by the leading-zero count,
    //                              exponent - count  (cancellation case)
    function automatic [4:0] lzc28(input [27:0] v);
        integer i;
        begin
            lzc28 = 5'd28;                       // all zero
            for (i = 27; i >= 0; i = i - 1)
                if (v[i] && lzc28 == 5'd28) lzc28 = 5'd27 - i[4:0];
        end
    endfunction

    wire [4:0] lz = lzc28(s2_sum);
    wire       sum_zero = (s2_sum == 28'd0);

    // After normalisation the implicit 1 sits at bit 26 of a 27-bit field.
    reg  [26:0] norm;
    reg  signed [9:0] nexp;
    always_comb begin
        if (s2_sum[27]) begin                    // carried out
            // Shifting right by one DISCARDS s2_sum[0]. That bit still carries
            // rounding information, so it must be OR'd into the sticky position
            // rather than dropped -- otherwise a value that should round up sees
            // sticky = 0 and rounds down instead.
            //
            // This was a real bug, and a subtle one: it made dot3 exactly 1 LSB
            // low, but only for inputs where the significand sum both carries out
            // AND has a 1 in the bit being discarded. tb_dot3's random vectors
            // (independent a and b) never hit it; pe_pair's dot3(d,d) -- summing
            // three squares, so always same-sign with no cancellation -- hit it on
            // 4 of 512 vectors. Coverage is about input DISTRIBUTION, not just
            // input count.
            norm = {s2_sum[27:2], s2_sum[1] | s2_sum[0]};
            nexp = $signed({2'b00, s2_exp}) + 10'sd1;
        end else if (s2_sum[26]) begin           // already normalised
            norm = s2_sum[26:0];
            nexp = $signed({2'b00, s2_exp});
        end else begin                           // cancellation: shift left
            norm = s2_sum[26:0] << (lz - 5'd1);
            nexp = $signed({2'b00, s2_exp}) - $signed({5'd0, (lz - 5'd1)});
        end
    end

    wire [22:0] man_pre = norm[25:3];
    wire        guard   = norm[2];
    wire        rnd     = norm[1];
    wire        sticky  = norm[0];
    wire        round_up = guard & (rnd | sticky | man_pre[0]);   // RNE

    wire [23:0] man_rnd = {1'b0, man_pre} + (round_up ? 24'd1 : 24'd0);
    // A carry out of the 23-bit fraction means the significand became exactly
    // 2.0 (the fraction was all ones). Represent that as 1.0 x 2^(e+1): the new
    // fraction is ZERO, not the old fraction shifted right. See the equivalent
    // comment in fp32_mul.sv -- the shifted version is a real bug that yields a
    // significand of 1.5 and hides from random stimulus.
    wire        rcarry  = man_rnd[23];
    wire [22:0] man_fin = rcarry ? 23'd0 : man_rnd[22:0];
    wire signed [9:0] exp_fin = nexp + (rcarry ? 10'sd1 : 10'sd0);

    wire ovf = (exp_fin >= 10'sd255);
    wire unf = (exp_fin <= 10'sd0);

    reg  [31:0] y_r;
    reg         v_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            v_r <= 1'b0;
            y_r <= 32'd0;
        end else begin
            v_r <= s2_v;
            if (s2_nan)               y_r <= {1'b0, 8'hFF, 23'h400000};
            else if (s2_inf)          y_r <= {s2_isgn, 8'hFF, 23'd0};
            else if (s2_bothzero)     y_r <= {s2_sgn, 8'h00, 23'd0};
            // Exact cancellation (x + (-x)) is +0 in IEEE-754 round-to-nearest,
            // regardless of the operands' signs.
            else if (sum_zero)        y_r <= 32'd0;
            else if (ovf)             y_r <= {s2_sgn, 8'hFF, 23'd0};
            else if (unf)             y_r <= {s2_sgn, 8'h00, 23'd0};
            else                      y_r <= {s2_sgn, exp_fin[7:0], man_fin};
        end
    end

    assign y     = y_r;
    assign v_out = v_r;

endmodule

`default_nettype wire

// ============================================================================
// tb_rsqrt.sv — testbench for the reciprocal-square-root unit
// ----------------------------------------------------------------------------
// Reads hw/tb/vectors/rsqrt_vectors.hex (x, expected) produced by
// hw/golden/model.py, which sweeps x geometrically from 1e-6 to 1e6.
//
// Unlike dot3, this is NOT checked bit-exact. rsqrt is an APPROXIMATION: a table
// lookup refined by Newton-Raphson. So the testbench measures ULP ERROR and
// asserts it stays within a stated budget. That budget is a hardware
// specification, and reporting the measured maximum is the deliverable -- not a
// pass/fail on equality.
//
// ULP = units in the last place. Because adjacent binary32 values differ by 1 in
// their integer bit pattern, |bits(a) - bits(b)| IS the ULP distance, which
// makes the measurement a subtraction rather than a floating-point comparison.
// It is also the right unit for a spec: "within 3 ULP" is a claim about the last
// two bits of the significand, independent of magnitude.
//
// Stimulus is driven on the NEGEDGE. Driving in the same timestep as the
// sampling posedge races with the DUT's always_ff blocks and can inject a phantom
// valid pulse -- a bug this project actually hit while bringing up tb_dot3.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_rsqrt;

    localparam int MAXV     = 1024;
    localparam int LUT_BITS = 6;
    localparam int NR_ITERS = 2;
    localparam int LATENCY  = 1 + NR_ITERS * 12;   // must match rsqrt.sv = 25
    // Accuracy budget. The golden model measures max 3 ULP for this design
    // point; we allow 4 so a benign last-bit difference in the RTL's rounding
    // does not fail the build, but anything larger is a real defect.
    localparam int ULP_BUDGET = 4;

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
    logic        v_in = 1'b0;
    logic [31:0] x;
    wire         v_out;
    wire [31:0]  y;
    wire         err;

    always #1 clk = ~clk;                          // 500 MHz

    rsqrt #(.LUT_BITS(LUT_BITS), .NR_ITERS(NR_ITERS),
            .LUT_FILE("rsqrt_lut.hex")) dut (
        .clk(clk), .rst_n(rst_n), .v_in(v_in), .x(x),
        .v_out(v_out), .y(y), .err(err)
    );

    logic [31:0] vx  [0:MAXV-1];
    logic [31:0] vy  [0:MAXV-1];
    int          nvec = 0;

    logic [31:0] exp_q [$];
    logic [31:0] in_q  [$];
    int          idx_q [$];

    int checked   = 0;
    int over      = 0;      // results outside the ULP budget
    int max_ulp   = 0;
    int worst_idx = -1;
    longint ulp_sum = 0;

    // ---------------- load vectors ------------------------------------------
    initial begin
        int fd, r;
        logic [31:0] a, b;
        fd = $fopen("vectors/rsqrt_vectors.hex", "r");
        if (fd == 0) begin
            $display("FATAL: cannot open vectors/rsqrt_vectors.hex");
            $finish;
        end
        r = 2;
        while (r == 2 && nvec < MAXV) begin
            r = $fscanf(fd, "%h %h", a, b);
            if (r == 2) begin
                vx[nvec] = a;
                vy[nvec] = b;
                nvec = nvec + 1;
            end
        end
        $fclose(fd);
        $display("tb_rsqrt: loaded %0d vectors", nvec);
    end

    // ---------------- drive (negedge) ---------------------------------------
    initial begin
        int i;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        for (i = 0; i < nvec; i++) begin
            x    = vx[i];
            v_in = 1'b1;
            exp_q.push_back(vy[i]);
            in_q.push_back(vx[i]);
            idx_q.push_back(i);
            @(negedge clk);
        end
        v_in = 1'b0;

        repeat (LATENCY + 8) @(negedge clk);

        $display("----------------------------------------------------------");
        $display("tb_rsqrt: checked %0d results", checked);
        $display("tb_rsqrt: max error %0d ULP (budget %0d), mean %0d/1000 ULP",
                 max_ulp, ULP_BUDGET,
                 (checked > 0) ? int'((ulp_sum * 1000) / checked) : 0);
        if (worst_idx >= 0)
            $display("tb_rsqrt: worst case at vector %0d, x=%h", worst_idx,
                     vx[worst_idx]);
        if (checked == nvec && over == 0)
            $display("tb_rsqrt: PASS");
        else
            $display("tb_rsqrt: FAIL (%0d of %0d checked, %0d over budget)",
                     checked, nvec, over);
        $display("----------------------------------------------------------");
        $finish;
    end

    // ---------------- check (negedge) ---------------------------------------
    always @(negedge clk) begin
        if (rst_n && v_out) begin
            logic [31:0] e, xi;
            int          k, d;
            if (exp_q.size() == 0) begin
                $display("ERROR: result with no pending expectation: y=%h", y);
                over++;
            end else begin
                e  = exp_q.pop_front();
                xi = in_q.pop_front();
                k  = idx_q.pop_front();
                checked++;
                // ULP distance = difference of the integer bit patterns.
                d = (y > e) ? int'(y - e) : int'(e - y);
                ulp_sum = ulp_sum + d;
                if (d > max_ulp) begin
                    max_ulp   = d;
                    worst_idx = k;
                end
                if (d > ULP_BUDGET) begin
                    over++;
                    if (over <= 10)
                        $display("OVER BUDGET vec[%0d] x=%h: got %h expected %h (%0d ULP)",
                                 k, xi, y, e, d);
                end
            end
        end
    end

    initial begin
        #400000;
        $display("tb_rsqrt: TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire

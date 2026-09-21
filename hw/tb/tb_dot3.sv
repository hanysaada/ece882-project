// ============================================================================
// tb_dot3.sv — testbench for dot3, checked against the golden model
// ----------------------------------------------------------------------------
// Reads hw/tb/vectors/dot3_vectors.hex, produced by hw/golden/model.py. Each
// line is 7 hex words: ax ay az bx by bz expected, all binary32 bit patterns.
//
// The check is BIT-EXACT. That is only legitimate because the golden model
// commits to the same adder-tree shape ((p0+p1)+p2) as the RTL; IEEE-754
// addition is not associative, so a different tree would legitimately differ in
// the last bit and this testbench would (correctly) fail.
//
// Stimulus is applied back-to-back, one vector per cycle, to exercise the
// initiation interval of 1 -- a design that only worked with gaps between inputs
// would pass a one-at-a-time test and fail here.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_dot3;

    localparam int MAXV    = 1024;
    localparam int LATENCY = 9;          // must match dot3.sv

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
    logic        v_in = 1'b0;
    logic [31:0] ax, ay, az, bx, by, bz;
    wire         v_out;
    wire [31:0]  y;

    always #1 clk = ~clk;                // 500 MHz => 2 ns period

    dot3 dut (.clk(clk), .rst_n(rst_n), .v_in(v_in),
              .ax(ax), .ay(ay), .az(az), .bx(bx), .by(by), .bz(bz),
              .v_out(v_out), .y(y));

    // ---------------- vector storage -----------------------------------------
    logic [31:0] vec [0:MAXV-1][0:6];
    int          nvec = 0;
    // expected results queued in issue order; compared as results emerge
    logic [31:0] exp_q [$];
    int          idx_q [$];

    int errors  = 0;
    int checked = 0;

    // ---------------- load vectors ------------------------------------------
    // Icarus does not support `break`, and $fgets/substr string handling is
    // patchy, so read with $fscanf in a loop guarded by its return value.
    // The vector files therefore contain no comment lines.
    initial begin
        int fd, r, i;
        logic [31:0] w0, w1, w2, w3, w4, w5, w6;
        fd = $fopen("vectors/dot3_vectors.hex", "r");
        if (fd == 0) begin
            $display("FATAL: cannot open vectors/dot3_vectors.hex");
            $finish;
        end
        r = 7;
        while (r == 7 && nvec < MAXV) begin
            r = $fscanf(fd, "%h %h %h %h %h %h %h",
                        w0, w1, w2, w3, w4, w5, w6);
            if (r == 7) begin
                vec[nvec][0] = w0; vec[nvec][1] = w1; vec[nvec][2] = w2;
                vec[nvec][3] = w3; vec[nvec][4] = w4; vec[nvec][5] = w5;
                vec[nvec][6] = w6;
                nvec = nvec + 1;
            end
        end
        $fclose(fd);
        $display("tb_dot3: loaded %0d vectors", nvec);
    end

    // ---------------- drive --------------------------------------------------
    // STIMULUS IS APPLIED ON THE NEGEDGE, never in the same timestep as the
    // posedge that samples it. Driving with blocking assignments immediately
    // after a posedge races with the DUT's own always_ff blocks: both sit in the
    // active region at the same simulation time, so whether the DUT sees the old
    // or the new value is undefined. That race made the DUT latch one EXTRA
    // valid pulse, which shifted every result by one and looked exactly like a
    // pipeline misalignment. The RTL was correct the whole time.
    initial begin
        int i;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // back-to-back issue, one vector per cycle (II = 1). Each value is set
        // at a negedge and held across exactly one posedge.
        for (i = 0; i < nvec; i++) begin
            ax = vec[i][0]; ay = vec[i][1]; az = vec[i][2];
            bx = vec[i][3]; by = vec[i][4]; bz = vec[i][5];
            v_in = 1'b1;
            exp_q.push_back(vec[i][6]);
            idx_q.push_back(i);
            @(negedge clk);
        end
        v_in = 1'b0;

        // drain the pipeline
        repeat (LATENCY + 8) @(negedge clk);

        $display("----------------------------------------------------------");
        $display("tb_dot3: checked %0d results, %0d error(s)", checked, errors);
        if (errors == 0 && checked == nvec)
            $display("tb_dot3: PASS");
        else
            $display("tb_dot3: FAIL (checked %0d of %0d)", checked, nvec);
        $display("----------------------------------------------------------");
        $finish;
    end

    // ---------------- check --------------------------------------------------
    // Sample on the NEGEDGE, not the posedge. A monitor clocked on the same edge
    // as the DUT races with it: the DUT's nonblocking assignments land in the NBA
    // region while the monitor reads in the active region, so which value you see
    // depends on scheduling. Sampling mid-cycle, when the outputs are settled,
    // removes the race entirely. This bug initially made every result look
    // off-by-one (got[i] == expected[i-1]) even though the RTL was correct.
    always @(negedge clk) begin
        if (rst_n && v_out) begin
            logic [31:0] e;
            int          k;
            if (exp_q.size() == 0) begin
                $display("ERROR: result with no pending expectation: y=%h", y);
                errors++;
            end else begin
                e = exp_q.pop_front();
                k = idx_q.pop_front();
                checked++;
                if (y !== e) begin
                    errors++;
                    if (errors <= 10)
                        $display("MISMATCH vec[%0d]: got %h expected %h", k, y, e);
                end
            end
        end
    end

    // ---------------- safety timeout ----------------------------------------
    initial begin
        #200000;
        $display("tb_dot3: TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire

// ============================================================================
// tb_pe_ray.sv — testbench for the ray/sphere intersection PE
// ----------------------------------------------------------------------------
// Vectors: hw/tb/vectors/pe_ray_vectors.hex, 9 fields per line:
//   cx cy cz rvx rvy rvz radius2  t hit
//
// Half the vectors are deliberate MISSES. That matters: the negative-discriminant
// path is not an edge case here, it is the common case in a real render (most
// rays miss most objects), and it is the path where rsqrt must never be handed a
// negative input. A testbench that only fed hits would leave the majority of real
// traffic unverified.
//
// On a miss `t` is meaningless by contract, so it is not compared -- only `hit`
// is. Comparing a value the interface declares invalid would be testing an
// accident rather than a specification.
//
// Driven back-to-back on the negedge, so the initiation interval of 1 is
// exercised with 512 tests in flight through a 49-cycle pipeline.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_pe_ray;

    localparam int MAXV    = 1024;
    localparam int LATENCY = 49;          // must match pe_ray.sv

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
    logic        v_in = 1'b0;
    logic [31:0] cx, cy, cz, rvx, rvy, rvz, radius2;
    wire         v_out, hit, err;
    wire [31:0]  t;

    always #1 clk = ~clk;

    pe_ray dut (
        .clk(clk), .rst_n(rst_n), .v_in(v_in),
        .cx(cx), .cy(cy), .cz(cz),
        .rvx(rvx), .rvy(rvy), .rvz(rvz),
        .radius2(radius2),
        .v_out(v_out), .t(t), .hit(hit), .err(err)
    );

    logic [31:0] vi   [0:MAXV-1][0:6];
    logic [31:0] vt   [0:MAXV-1];
    logic        vh   [0:MAXV-1];
    int          nvec = 0;

    int idx_q [$];
    int errors = 0, checked = 0, nhit = 0, nmiss = 0;

    // ---------------- load ---------------------------------------------------
    initial begin
        int fd, r, h;
        logic [31:0] w [0:7];
        fd = $fopen("vectors/pe_ray_vectors.hex", "r");
        if (fd == 0) begin
            $display("FATAL: cannot open vectors/pe_ray_vectors.hex");
            $finish;
        end
        r = 9;
        while (r == 9 && nvec < MAXV) begin
            r = $fscanf(fd, "%h %h %h %h %h %h %h %h %d",
                        w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], h);
            if (r == 9) begin
                vi[nvec][0]=w[0]; vi[nvec][1]=w[1]; vi[nvec][2]=w[2];
                vi[nvec][3]=w[3]; vi[nvec][4]=w[4]; vi[nvec][5]=w[5];
                vi[nvec][6]=w[6];
                vt[nvec]=w[7];  vh[nvec]=h[0];
                nvec = nvec + 1;
            end
        end
        $fclose(fd);
        $display("tb_pe_ray: loaded %0d vectors", nvec);
    end

    // ---------------- drive --------------------------------------------------
    initial begin
        int i;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        for (i = 0; i < nvec; i++) begin
            cx = vi[i][0]; cy = vi[i][1]; cz = vi[i][2];
            rvx= vi[i][3]; rvy= vi[i][4]; rvz= vi[i][5];
            radius2 = vi[i][6];
            v_in = 1'b1;
            idx_q.push_back(i);
            @(negedge clk);
        end
        v_in = 1'b0;

        repeat (LATENCY + 8) @(negedge clk);

        $display("----------------------------------------------------------");
        $display("tb_pe_ray: checked %0d results (%0d hits, %0d misses), %0d error(s)",
                 checked, nhit, nmiss, errors);
        if (errors == 0 && checked == nvec && nhit > 0 && nmiss > 0)
            $display("tb_pe_ray: PASS");
        else
            $display("tb_pe_ray: FAIL (checked %0d of %0d, hits %0d, misses %0d)",
                     checked, nvec, nhit, nmiss);
        $display("----------------------------------------------------------");
        $finish;
    end

    // ---------------- check --------------------------------------------------
    always @(negedge clk) begin
        if (rst_n && v_out) begin
            int k;
            if (idx_q.size() == 0) begin
                $display("ERROR: result with no pending expectation");
                errors++;
            end else begin
                k = idx_q.pop_front();
                checked++;
                if (vh[k]) nhit++; else nmiss++;

                if (hit !== vh[k]) begin
                    errors++;
                    if (errors <= 10)
                        $display("HIT MISMATCH vec[%0d]: got %b expected %b",
                                 k, hit, vh[k]);
                end else if (vh[k] && (t !== vt[k])) begin
                    // t is only meaningful on a hit
                    errors++;
                    if (errors <= 10)
                        $display("T MISMATCH vec[%0d]: got %h expected %h",
                                 k, t, vt[k]);
                end

                if (err) begin
                    // rsqrt must never see a bad input: misses are diverted to
                    // 1.0 before the unit, so err firing means a real defect.
                    $display("ERROR flag raised on vec[%0d] (hit=%b)", k, hit);
                    errors++;
                end
            end
        end
    end

    initial begin
        #400000;
        $display("tb_pe_ray: TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire

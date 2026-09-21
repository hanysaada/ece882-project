// ============================================================================
// tb_pe_pair.sv — testbench for the nbody pair processing element
// ----------------------------------------------------------------------------
// Vectors: hw/tb/vectors/pe_pair_vectors.hex, 13 hex words per line:
//   dx dy dz dt m1 m2  dv1x dv1y dv1z dv2x dv2y dv2z mag
//
// Checked BIT-EXACT. The golden model performs the same operations in the same
// order with a binary32 rounding after each, so any difference is a real defect
// rather than a legitimate reassociation.
//
// Stimulus is driven back-to-back on the NEGEDGE, so this also proves the
// initiation interval really is 1: 49 cycles of latency with 512 pairs in flight
// means the delay lines for dx, dy, dz, dt, m1 and m2 must all be balanced
// correctly. A design that only worked one-pair-at-a-time would pass a naive
// test and fail here.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_pe_pair;

    localparam int MAXV    = 1024;
    localparam int LATENCY = 49;          // must match pe_pair.sv

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
    logic        v_in = 1'b0;
    logic [31:0] dx, dy, dz, dt, m1, m2;
    wire         v_out, err;
    wire [31:0]  dv1x, dv1y, dv1z, dv2x, dv2y, dv2z, mag_out;

    always #1 clk = ~clk;                 // 500 MHz

    pe_pair dut (
        .clk(clk), .rst_n(rst_n), .v_in(v_in),
        .dx(dx), .dy(dy), .dz(dz), .dt(dt), .m1(m1), .m2(m2),
        .v_out(v_out),
        .dv1x(dv1x), .dv1y(dv1y), .dv1z(dv1z),
        .dv2x(dv2x), .dv2y(dv2y), .dv2z(dv2z),
        .mag_out(mag_out), .err(err)
    );

    logic [31:0] vin  [0:MAXV-1][0:5];
    logic [31:0] vexp [0:MAXV-1][0:6];
    int          nvec = 0;

    int          idx_q [$];
    int          errors = 0, checked = 0;

    // ---------------- load vectors ------------------------------------------
    initial begin
        int fd, r;
        logic [31:0] w [0:12];
        fd = $fopen("vectors/pe_pair_vectors.hex", "r");
        if (fd == 0) begin
            $display("FATAL: cannot open vectors/pe_pair_vectors.hex");
            $finish;
        end
        r = 13;
        while (r == 13 && nvec < MAXV) begin
            r = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h",
                        w[0], w[1], w[2], w[3], w[4], w[5], w[6],
                        w[7], w[8], w[9], w[10], w[11], w[12]);
            if (r == 13) begin
                vin[nvec][0]=w[0]; vin[nvec][1]=w[1]; vin[nvec][2]=w[2];
                vin[nvec][3]=w[3]; vin[nvec][4]=w[4]; vin[nvec][5]=w[5];
                vexp[nvec][0]=w[6];  vexp[nvec][1]=w[7];  vexp[nvec][2]=w[8];
                vexp[nvec][3]=w[9];  vexp[nvec][4]=w[10]; vexp[nvec][5]=w[11];
                vexp[nvec][6]=w[12];
                nvec = nvec + 1;
            end
        end
        $fclose(fd);
        $display("tb_pe_pair: loaded %0d vectors", nvec);
    end

    // ---------------- drive --------------------------------------------------
    initial begin
        int i;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        for (i = 0; i < nvec; i++) begin
            dx = vin[i][0]; dy = vin[i][1]; dz = vin[i][2];
            dt = vin[i][3]; m1 = vin[i][4]; m2 = vin[i][5];
            v_in = 1'b1;
            idx_q.push_back(i);
            @(negedge clk);
        end
        v_in = 1'b0;

        repeat (LATENCY + 8) @(negedge clk);

        $display("----------------------------------------------------------");
        $display("tb_pe_pair: checked %0d results, %0d error(s)", checked, errors);
        if (errors == 0 && checked == nvec)
            $display("tb_pe_pair: PASS");
        else
            $display("tb_pe_pair: FAIL (checked %0d of %0d)", checked, nvec);
        $display("----------------------------------------------------------");
        $finish;
    end

    // ---------------- check --------------------------------------------------
    always @(negedge clk) begin
        if (rst_n && v_out) begin
            int k;
            logic [31:0] got [0:6];
            string names [0:6];
            int j, bad;
            if (idx_q.size() == 0) begin
                $display("ERROR: result with no pending expectation");
                errors++;
            end else begin
                k = idx_q.pop_front();
                checked++;
                got[0]=dv1x; got[1]=dv1y; got[2]=dv1z;
                got[3]=dv2x; got[4]=dv2y; got[5]=dv2z; got[6]=mag_out;
                names[0]="dv1x"; names[1]="dv1y"; names[2]="dv1z";
                names[3]="dv2x"; names[4]="dv2y"; names[5]="dv2z";
                names[6]="mag";
                bad = 0;
                for (j = 0; j <= 6; j++) begin
                    if (got[j] !== vexp[k][j]) begin
                        bad = 1;
                        if (errors < 6)
                            $display("MISMATCH vec[%0d].%s: got %h expected %h",
                                     k, names[j], got[j], vexp[k][j]);
                    end
                end
                if (bad) errors++;
                if (err) begin
                    $display("ERROR flag raised on vec[%0d]", k);
                    errors++;
                end
            end
        end
    end

    initial begin
        #400000;
        $display("tb_pe_pair: TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire

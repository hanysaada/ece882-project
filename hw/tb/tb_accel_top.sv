// ============================================================================
// tb_accel_top.sv — system-level test: descriptor in, body array out
// ----------------------------------------------------------------------------
// This is the test that proves the INTERFACE works, not just the datapath.
// It exercises the whole intended flow:
//
//   write descriptor -> START -> DMA in -> stream pairs -> accumulate ->
//   integrate -> DMA out -> DONE
//
// A simple word-addressed memory model stands in for host DRAM, preloaded with a
// body array by the driving process. Expected results come from
// hw/tb/vectors/accel_expected.hex, which hw/golden/model.py produces by running
// the SAME simulation in the golden model's binary32 arithmetic. So this is an
// end-to-end bit-exact check of the accelerator against a validated reference.
//
// The memory model deliberately returns read data with ONE cycle of latency and
// can be made to stall writes, so the FSM's handshaking is exercised rather than
// assumed. A design that only worked with zero-latency memory would pass a
// combinational stub and fail on real hardware.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_accel_top;

    localparam int NBODIES  = 5;         // nbody's configuration: sun + 4 giants
    localparam int WPB      = 8;         // words per body
    localparam int NWORDS   = NBODIES * WPB;
    localparam int MEMW     = 1024;
    localparam int BASE     = 0;         // byte address of the body array
    localparam int NSTEPS   = 4;

    logic clk = 1'b0, rst_n = 1'b0;
    always #1 clk = ~clk;                // 500 MHz

    // ---- CSR bus ----
    logic        csr_wvalid = 1'b0;
    logic [7:0]  csr_waddr;
    logic [31:0] csr_wdata;
    logic        csr_rvalid = 1'b0;
    logic [7:0]  csr_raddr;
    wire  [31:0] csr_rdata;

    // ---- DMA bus ----
    wire         m_rreq;
    wire [31:0]  m_raddr;
    logic        m_rvalid = 1'b0;
    logic [31:0] m_rdata  = 32'd0;
    wire         m_wreq;
    wire [31:0]  m_waddr;
    wire [31:0]  m_wdata;
    logic        m_wready = 1'b1;
    wire         irq;

    accel_top #(.MAX_BODIES(64), .ADDR_W(32)) dut (
        .clk(clk), .rst_n(rst_n),
        .csr_wvalid(csr_wvalid), .csr_waddr(csr_waddr), .csr_wdata(csr_wdata),
        .csr_rvalid(csr_rvalid), .csr_raddr(csr_raddr), .csr_rdata(csr_rdata),
        .m_rreq(m_rreq), .m_raddr(m_raddr), .m_rvalid(m_rvalid), .m_rdata(m_rdata),
        .m_wreq(m_wreq), .m_waddr(m_waddr), .m_wdata(m_wdata), .m_wready(m_wready),
        .irq(irq)
    );

    // ---------------- memory model -------------------------------------------
    // One cycle of read latency, so the FSM must actually wait for m_rvalid.
    logic [31:0] mem [0:MEMW-1];
    int          nwrites = 0;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            m_rvalid <= 1'b0;
        end else begin
            m_rvalid <= m_rreq;                       // 1-cycle latency
            if (m_rreq) m_rdata <= mem[m_raddr >> 2];
            if (m_wreq && m_wready) begin
                mem[m_waddr >> 2] <= m_wdata;
                nwrites <= nwrites + 1;
            end
        end
    end

    // ---------------- CSR helper tasks ---------------------------------------
    task automatic csr_write(input [7:0] a, input [31:0] d);
        begin
            @(negedge clk);
            csr_waddr  = a;
            csr_wdata  = d;
            csr_wvalid = 1'b1;
            @(negedge clk);
            csr_wvalid = 1'b0;
        end
    endtask

    task automatic csr_read(input [7:0] a, output [31:0] d);
        begin
            @(negedge clk);
            csr_raddr  = a;
            csr_rvalid = 1'b1;
            @(negedge clk);
            csr_rvalid = 1'b0;
            @(negedge clk);                            // registered read data
            d = csr_rdata;
        end
    endtask

    // ---------------- expected results --------------------------------------
    logic [31:0] exp_mem [0:NWORDS-1];
    int          nexp = 0;

    initial begin
        int fd, r;
        logic [31:0] w;
        fd = $fopen("vectors/accel_expected.hex", "r");
        if (fd == 0) begin
            $display("FATAL: cannot open vectors/accel_expected.hex");
            $finish;
        end
        r = 1;
        while (r == 1 && nexp < NWORDS) begin
            r = $fscanf(fd, "%h", w);
            if (r == 1) begin
                exp_mem[nexp] = w;
                nexp = nexp + 1;
            end
        end
        $fclose(fd);
    end

    // ---------------- initial body array ------------------------------------
    initial begin
        int fd, r, i;
        logic [31:0] w;
        for (i = 0; i < MEMW; i++) mem[i] = 32'd0;
        fd = $fopen("vectors/accel_input.hex", "r");
        if (fd == 0) begin
            $display("FATAL: cannot open vectors/accel_input.hex");
            $finish;
        end
        i = 0;
        r = 1;
        while (r == 1 && i < NWORDS) begin
            r = $fscanf(fd, "%h", w);
            if (r == 1) begin
                mem[i] = w;
                i = i + 1;
            end
        end
        $fclose(fd);
        $display("tb_accel_top: loaded %0d input words", i);
    end

    // ---------------- the test ----------------------------------------------
    int errors = 0;

    initial begin
        logic [31:0] st, pairs, cycles;
        int i, guard;
        real dtv;

        repeat (6) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // ---- program the descriptor ----
        csr_write(8'h08, BASE);            // BODY_PTR
        csr_write(8'h0C, NBODIES);         // N_BODIES
        csr_write(8'h10, 32'h3C23D70A);    // DT = 0.01f
        csr_write(8'h14, NSTEPS);          // N_STEPS
        $display("tb_accel_top: descriptor written (n=%0d, steps=%0d)",
                 NBODIES, NSTEPS);

        // ---- read it back, proving the CSR block works ----
        csr_read(8'h0C, st);
        if (st !== NBODIES) begin
            $display("ERROR: N_BODIES read back as %0d, expected %0d", st, NBODIES);
            errors++;
        end
        csr_read(8'h10, st);
        if (st !== 32'h3C23D70A) begin
            $display("ERROR: DT read back as %h", st);
            errors++;
        end

        // ---- START ----
        csr_write(8'h00, 32'h1);

        // ---- poll STATUS.DONE ----
        guard = 0;
        st    = 32'd0;
        while (st[0] !== 1'b1 && guard < 200000) begin
            csr_read(8'h04, st);
            guard = guard + 1;
        end
        if (st[0] !== 1'b1) begin
            $display("ERROR: engine never asserted DONE (STATUS=%h)", st);
            errors++;
        end else begin
            $display("tb_accel_top: DONE after %0d status polls", guard);
        end
        if (st[2]) begin
            $display("ERROR: STATUS.ERR is set");
            errors++;
        end

        // ---- performance counters ----
        csr_read(8'h18, pairs);
        csr_read(8'h1C, cycles);
        // n(n-1), NOT n(n-1)/2: the engine computes the force on each body from
        // every other body separately rather than exploiting Newton's third law,
        // because accumulating onto both bodies of a pair would be a
        // read-after-write hazard on in-flight state. See accel_top.sv.
        $display("tb_accel_top: pairs=%0d cycles=%0d  (expect pairs = %0d)",
                 pairs, cycles, (NBODIES*(NBODIES-1)) * NSTEPS);
        if (pairs !== (NBODIES*(NBODIES-1)) * NSTEPS) begin
            $display("ERROR: pair count wrong");
            errors++;
        end

        // ---- the body array must have been written back ----
        if (nwrites != NWORDS) begin
            $display("ERROR: %0d words written back, expected %0d",
                     nwrites, NWORDS);
            errors++;
        end

        // ---- compare against the golden model ----
        for (i = 0; i < NWORDS; i++) begin
            // word 7 of each body is padding and is not written meaningfully
            if ((i % WPB) != 7) begin
                if (mem[i] !== exp_mem[i]) begin
                    if (errors < 12)
                        $display("MISMATCH word %0d (body %0d %s): got %h expected %h",
                                 i, i / WPB,
                                 ((i%WPB)==0)?"px":((i%WPB)==1)?"py":((i%WPB)==2)?"pz":
                                 ((i%WPB)==3)?"vx":((i%WPB)==4)?"vy":((i%WPB)==5)?"vz":"ms",
                                 mem[i], exp_mem[i]);
                    errors++;
                end
            end
        end

        $display("----------------------------------------------------------");
        if (errors == 0) $display("tb_accel_top: PASS");
        else             $display("tb_accel_top: FAIL (%0d error(s))", errors);
        $display("----------------------------------------------------------");
        $finish;
    end

    initial begin
        #4000000;
        $display("tb_accel_top: TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire

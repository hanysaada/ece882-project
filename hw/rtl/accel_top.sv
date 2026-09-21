// ============================================================================
// accel_top.sv — memory-mapped accelerator: CSR block, DMA engine, control FSM
// ----------------------------------------------------------------------------
// WHY THIS MODULE EXISTS, AND WHY IT LOOKS LIKE THIS
//
// The datapath (pe_pair) is the easy part. What decides whether any of its speedup
// survives is how much work crosses the Python boundary per invocation, and we
// MEASURED that boundary (results/hw/call_overhead.txt):
//
//     ctypes call with 3 double arguments   595 ns
//     pe_pair latency                        68 ns   (34 cycles at 500 MHz)
//     pe_pair throughput interval             2 ns   (II = 1)
//
// A per-operation interface -- accel.pair(dx,dy,dz,dt,m1,m2) once per body pair --
// pays 595 ns to do 2 ns of work. It would be 8.75x SLOWER than the hardware
// latency it is trying to hide. So the interface cannot be a register you poke per
// operation; it has to be a DESCRIPTOR that hands over a whole batch.
//
// Measured amortisation:
//        10 pairs/call   68.30 ns/pair   crossing is 87.1% of the call
//      1000 pairs/call    2.66 ns/pair   crossing is 22.3%
//     10000 pairs/call    2.07 ns/pair   crossing is  2.9%
//
// nbody's own configuration is 5 bodies = 10 unique pairs per timestep, so one
// call per timestep is NOT enough -- at 10 pairs the crossing is still 87% of the
// call. Hence the descriptor carries a STEP COUNT: the CPU hands over the body
// array once and the engine runs many timesteps internally, writing state back
// only at the end. That is the whole reason this module exists.
//
// ----------------------------------------------------------------------------
// PROGRAMMING MODEL
//
//   1. CPU writes the descriptor into the CSRs (base address, body count, dt,
//      step count).
//   2. CPU writes START = 1 in CTRL.
//   3. Engine DMAs the body array into on-chip SRAM.
//   4. For each timestep: stream every unique pair through pe_pair, accumulate
//      the velocity deltas, then integrate positions.
//   5. Engine DMAs the body array back out and sets DONE, optionally raising an
//      interrupt.
//   6. CPU polls STATUS.DONE or takes the interrupt.
//
// CSR MAP (AXI4-Lite slave, 32-bit registers, byte address)
//   0x00  CTRL     W1S  bit0 START, bit1 IRQ_EN, bit2 ABORT
//   0x04  STATUS   RO   bit0 DONE, bit1 BUSY, bit2 ERR, bit3 IRQ
//   0x08  BODY_PTR RW   base address of the body array in host memory
//   0x0C  N_BODIES RW   number of bodies
//   0x10  DT       RW   timestep, binary32
//   0x14  N_STEPS  RW   timesteps to run before writing back
//   0x18  PAIRS_LO RO   pairs processed, low 32 bits  (performance counter)
//   0x1C  CYCLES   RO   busy cycles                   (performance counter)
//
// The two performance counters are not decoration: they let the driver report
// achieved pairs/cycle, which is how you find out whether the engine is
// compute-bound or memory-bound on real data instead of guessing.
//
// BODY ARRAY LAYOUT in host memory, 8 words (32 B) per body:
//   +0 x  +4 y  +8 z  +12 vx  +16 vy  +20 vz  +24 mass  +28 pad
// 32 B is one power-of-two stride, so a body never straddles a 64 B cache line
// and the DMA burst length is trivial to compute. The pad word costs 12.5% of
// bandwidth and buys aligned, single-burst access per body.
//
// ----------------------------------------------------------------------------
// SCOPE, STATED HONESTLY
// The AXI interfaces here are SIMPLIFIED: a single-beat AXI4-Lite-style CSR slave
// and a simple sequential read/write master, not a burst-optimised,
// protocol-complete AXI4 implementation with outstanding transactions and
// reordering. The assignment asks for a design that is complete and logically
// consistent, not tape-out ready, and a full AXI implementation would add a great
// deal of code without changing the argument being made. hw/tb/tb_accel_top.sv
// drives it with a simple memory model.
//
// Interface contract
//   CSR reads/writes complete in 1 cycle. Engine throughput is 1 pair/cycle once
//   streaming, plus DMA in and out. TARGET FREQUENCY 500 MHz.
// ============================================================================
`default_nettype none

module accel_top #(
    parameter int MAX_BODIES = 64,
    parameter int ADDR_W     = 32
) (
    input  wire                clk,
    input  wire                rst_n,

    // ---- AXI4-Lite-style CSR slave (simplified: single beat, always ready) --
    input  wire                csr_wvalid,
    input  wire [7:0]          csr_waddr,
    input  wire [31:0]         csr_wdata,
    input  wire                csr_rvalid,
    input  wire [7:0]          csr_raddr,
    output wire [31:0]         csr_rdata,

    // ---- AXI4-style master for DMA (simplified: one word per request) -------
    output wire                m_rreq,
    output wire [ADDR_W-1:0]   m_raddr,
    input  wire                m_rvalid,       // data returned this cycle
    input  wire [31:0]         m_rdata,
    output wire                m_wreq,
    output wire [ADDR_W-1:0]   m_waddr,
    output wire [31:0]         m_wdata,
    input  wire                m_wready,

    output wire                irq
);

    // ---------------- CSRs ---------------------------------------------------
    localparam [7:0] A_CTRL     = 8'h00;
    localparam [7:0] A_STATUS   = 8'h04;
    localparam [7:0] A_BODY_PTR = 8'h08;
    localparam [7:0] A_N_BODIES = 8'h0C;
    localparam [7:0] A_DT       = 8'h10;
    localparam [7:0] A_N_STEPS  = 8'h14;
    localparam [7:0] A_PAIRS    = 8'h18;
    localparam [7:0] A_CYCLES   = 8'h1C;

    reg [ADDR_W-1:0] body_ptr;
    reg [31:0]       n_bodies;
    reg [31:0]       dt_r;
    reg [31:0]       n_steps;
    reg              irq_en;
    reg              start_pulse;
    reg              abort_r;

    reg              busy, done_r, err_r, irq_r;
    reg [31:0]       pairs_cnt, cycles_cnt;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            body_ptr    <= '0;
            n_bodies    <= '0;
            dt_r        <= '0;
            n_steps     <= 32'd1;
            irq_en      <= 1'b0;
            start_pulse <= 1'b0;
            abort_r     <= 1'b0;
        end else begin
            start_pulse <= 1'b0;                     // START is a pulse, not a level
            abort_r     <= 1'b0;
            if (csr_wvalid) begin
                case (csr_waddr)
                    A_CTRL: begin
                        // Writing START while BUSY is ignored rather than
                        // corrupting an in-flight run: a driver bug should not be
                        // able to desynchronise the engine.
                        if (csr_wdata[0] && !busy) start_pulse <= 1'b1;
                        irq_en  <= csr_wdata[1];
                        if (csr_wdata[2]) abort_r <= 1'b1;
                    end
                    A_BODY_PTR: body_ptr <= csr_wdata[ADDR_W-1:0];
                    A_N_BODIES: n_bodies <= csr_wdata;
                    A_DT:       dt_r     <= csr_wdata;
                    A_N_STEPS:  n_steps  <= (csr_wdata == 32'd0) ? 32'd1 : csr_wdata;
                    default: ;                        // writes to RO regs ignored
                endcase
            end
        end
    end

    reg [31:0] rdata_r;
    always_ff @(posedge clk) begin
        if (!rst_n) rdata_r <= 32'd0;
        else if (csr_rvalid) begin
            case (csr_raddr)
                A_CTRL:     rdata_r <= {29'd0, 1'b0, irq_en, 1'b0};
                A_STATUS:   rdata_r <= {28'd0, irq_r, err_r, busy, done_r};
                A_BODY_PTR: rdata_r <= {{(32-ADDR_W){1'b0}}, body_ptr};
                A_N_BODIES: rdata_r <= n_bodies;
                A_DT:       rdata_r <= dt_r;
                A_N_STEPS:  rdata_r <= n_steps;
                A_PAIRS:    rdata_r <= pairs_cnt;
                A_CYCLES:   rdata_r <= cycles_cnt;
                default:    rdata_r <= 32'hDEAD_BEEF;
            endcase
        end
    end
    assign csr_rdata = rdata_r;
    assign irq       = irq_r;

    // ---------------- on-chip body storage -----------------------------------
    // Positions, velocities and masses live on chip for the whole run. This is
    // the point of the descriptor interface: the array crosses the bus ONCE, not
    // once per timestep.
    reg [31:0] px [0:MAX_BODIES-1];
    reg [31:0] py [0:MAX_BODIES-1];
    reg [31:0] pz [0:MAX_BODIES-1];
    reg [31:0] vx [0:MAX_BODIES-1];
    reg [31:0] vy [0:MAX_BODIES-1];
    reg [31:0] vz [0:MAX_BODIES-1];
    reg [31:0] ms [0:MAX_BODIES-1];

    // ---------------- control FSM -------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE,        // waiting for START
        S_LOAD_REQ,    // issue a DMA read
        S_LOAD_WAIT,   // wait for the word
        S_PAIR_ISSUE,  // stream all j != i into pe_pair
        S_PAIR_DRAIN,  // let the pipeline empty for this i
        S_REDUCE,      // sum the partial accumulators onto body i
        S_REDUCE_WAIT, // wait for the reduction to land
        S_INTEGRATE,   // positions += dt * velocities
        S_STEP_DONE,   // another timestep, or write back?
        S_STORE_REQ,   // issue a DMA write
        S_STORE_WAIT,  // wait for write acceptance
        S_DONE
    } state_e;

    state_e state, state_n;

    reg [31:0] li;            // load/store index: which word of which body
    reg [31:0] step;          // current timestep
    reg [31:0] pi, pj;        // pair indices, i < j
    reg [31:0] ii;            // integrate index

    wire [31:0] words_total = n_bodies << 3;      // 8 words per body

    // ---------------- stage A: form the position deltas ----------------------
    // pe_pair consumes (dx,dy,dz) = pos_i - pos_j, NOT the positions themselves.
    // Subtraction is addition with the sign bit flipped, which is free, so this
    // costs three fp32_add instances and 3 cycles of latency.
    localparam int SUB_LAT = 3;

    reg         iss_v;                     // a pair was issued this cycle
    reg  [15:0] iss_i, iss_j;
    reg  [31:0] a_px, a_py, a_pz, b_px, b_py, b_pz, a_m, b_m;

    wire [31:0] nb_px = {~b_px[31], b_px[30:0]};
    wire [31:0] nb_py = {~b_py[31], b_py[30:0]};
    wire [31:0] nb_pz = {~b_pz[31], b_pz[30:0]};

    wire        sub_v;
    wire [31:0] d_x, d_y, d_z;
    fp32_add u_sub_x (.clk(clk), .rst_n(rst_n), .v_in(iss_v),
                      .a(a_px), .b(nb_px), .v_out(sub_v), .y(d_x));
    fp32_add u_sub_y (.clk(clk), .rst_n(rst_n), .v_in(iss_v),
                      .a(a_py), .b(nb_py), .v_out(),      .y(d_y));
    fp32_add u_sub_z (.clk(clk), .rst_n(rst_n), .v_in(iss_v),
                      .a(a_pz), .b(nb_pz), .v_out(),      .y(d_z));

    // masses and body indices must arrive at the PE with their deltas
    wire [31:0] m1_al, m2_al;
    wire [15:0] i_al, j_al;
    delay_line #(.WIDTH(32), .DEPTH(SUB_LAT)) u_dl_m1a
        (.clk(clk), .rst_n(rst_n), .d(a_m),   .q(m1_al));
    delay_line #(.WIDTH(32), .DEPTH(SUB_LAT)) u_dl_m2a
        (.clk(clk), .rst_n(rst_n), .d(b_m),   .q(m2_al));
    delay_line #(.WIDTH(16), .DEPTH(SUB_LAT)) u_dl_ia
        (.clk(clk), .rst_n(rst_n), .d(iss_i), .q(i_al));
    delay_line #(.WIDTH(16), .DEPTH(SUB_LAT)) u_dl_ja
        (.clk(clk), .rst_n(rst_n), .d(iss_j), .q(j_al));

    // ---------------- stage B: the pair PE -----------------------------------
    wire        pe_v_out, pe_err;
    wire [31:0] dv1x, dv1y, dv1z, dv2x, dv2y, dv2z, pe_mag;

    pe_pair u_pe (
        .clk(clk), .rst_n(rst_n), .v_in(sub_v),
        .dx(d_x), .dy(d_y), .dz(d_z),
        .dt(dt_r), .m1(m1_al), .m2(m2_al),
        .v_out(pe_v_out),
        .dv1x(dv1x), .dv1y(dv1y), .dv1z(dv1z),
        .dv2x(dv2x), .dv2y(dv2y), .dv2z(dv2z),
        .mag_out(pe_mag), .err(pe_err)
    );

    // The PE returns deltas 49 cycles after ITS input, so the body indices must
    // travel alongside. Because the PE is a fixed-latency pipeline with II = 1,
    // results emerge in issue order, so a delay line is sufficient -- no tag
    // matching or reorder buffer is needed. That is a direct benefit of the
    // systolic, control-free style: ordering is a property of the structure.
    localparam int TAGD = 49;
    wire [15:0] tag_i_out, tag_j_out;
    delay_line #(.WIDTH(16), .DEPTH(TAGD)) u_tag_i
        (.clk(clk), .rst_n(rst_n), .d(i_al), .q(tag_i_out));
    delay_line #(.WIDTH(16), .DEPTH(TAGD)) u_tag_j
        (.clk(clk), .rst_n(rst_n), .d(j_al), .q(tag_j_out));

    // ---------------- velocity accumulation, hazard-free ---------------------
    //
    // THE BUG THIS STRUCTURE EXISTS TO AVOID
    // The obvious design accumulates straight into the velocity array:
    //     vx[i] <= vx[i] + delta
    // With a 3-cycle adder and one pair issued per cycle, that is a
    // read-after-write hazard. nbody's pairs for body 0 are (0,1),(0,2),(0,3),
    // (0,4) on CONSECUTIVE cycles, so pair (0,2) reads vx[0] three cycles before
    // pair (0,1)'s result has been written. Updates are silently lost. Measured
    // symptom: the Sun, which appears in the most pairs, was wrong by far the
    // most, while bodies appearing in fewer pairs were off by only a few ULP.
    //
    // THE FIX, AND WHY IT IS THE STANDARD ONE
    // Restructure so no shared location is read-modify-written while in flight:
    //
    //   1. Iterate i in the outer loop and ALL j != i in the inner loop, and
    //      accumulate only the force on body i. Newton's third law is then not
    //      exploited, so the pair count doubles from n(n-1)/2 to n(n-1) -- but
    //      there is no write to body j at all, which removes half the hazard.
    //   2. For the remaining sequential accumulation onto body i, use NPART
    //      partial accumulators in round-robin. With adder latency L, touching a
    //      given partial only every NPART >= L+1 cycles means its previous result
    //      has always landed. Reduce the partials once per body at the end.
    //
    // This keeps the initiation interval at 1 -- no stalling -- which matters
    // because the whole performance claim rests on streaming one pair per cycle.
    // The cost is 2x the pair work and NPART*3 accumulator registers.
    localparam int NPART = 4;            // > fp32_add latency of 3

    reg [31:0] accx [0:NPART-1];
    reg [31:0] accy [0:NPART-1];
    reg [31:0] accz [0:NPART-1];
    reg [1:0]  psel;                     // which partial the RESULT belongs to

    // psel must follow the pipeline. Total issue-to-result latency is
    // SUB_LAT + pe_pair latency = 3 + 49 = 52, NOT 49: the delta-subtract stage
    // sits in front of the PE. Delaying by 49 made the partial-accumulator
    // selector run 3 cycles ahead of its own data, so results landed in the wrong
    // partial. tag_i/tag_j avoid this by construction because they are fed from
    // i_al/j_al, which are already delayed by SUB_LAT.
    wire [1:0] psel_res;
    delay_line #(.WIDTH(2), .DEPTH(SUB_LAT + TAGD)) u_psel
        (.clk(clk), .rst_n(rst_n), .d(psel), .q(psel_res));

    // Force on body i from body j is -(d * m_j * mag), which is exactly pe_pair's
    // dv1 output. We negate by flipping the sign bit, which is free.
    wire [31:0] n_dv1x = {~dv1x[31], dv1x[30:0]};
    wire [31:0] n_dv1y = {~dv1y[31], dv1y[30:0]};
    wire [31:0] n_dv1z = {~dv1z[31], dv1z[30:0]};

    wire        acc_v;
    wire [31:0] accx_n, accy_n, accz_n;
    fp32_add u_accx (.clk(clk), .rst_n(rst_n), .v_in(pe_v_out),
                     .a(accx[psel_res]), .b(n_dv1x), .v_out(acc_v), .y(accx_n));
    fp32_add u_accy (.clk(clk), .rst_n(rst_n), .v_in(pe_v_out),
                     .a(accy[psel_res]), .b(n_dv1y), .v_out(),      .y(accy_n));
    fp32_add u_accz (.clk(clk), .rst_n(rst_n), .v_in(pe_v_out),
                     .a(accz[psel_res]), .b(n_dv1z), .v_out(),      .y(accz_n));

    wire [1:0] psel_wb;
    delay_line #(.WIDTH(2), .DEPTH(3)) u_psel_wb
        (.clk(clk), .rst_n(rst_n), .d(psel_res), .q(psel_wb));

    reg        acc_clear;
    always_ff @(posedge clk) begin : p_acc
        integer k;
        if (!rst_n || acc_clear) begin
            for (k = 0; k < NPART; k = k + 1) begin
                accx[k] <= 32'd0; accy[k] <= 32'd0; accz[k] <= 32'd0;
            end
        end else if (acc_v) begin
            accx[psel_wb] <= accx_n;
            accy[psel_wb] <= accy_n;
            accz[psel_wb] <= accz_n;
        end
    end

    // Reduce the four partials: (0+1) + (2+3), a 2-level tree, 6 cycles.
    reg         red_go;
    wire        red_v1;
    wire [31:0] rx01, ry01, rz01, rx23, ry23, rz23;
    fp32_add u_rx01 (.clk(clk),.rst_n(rst_n),.v_in(red_go),
                     .a(accx[0]),.b(accx[1]),.v_out(red_v1),.y(rx01));
    fp32_add u_ry01 (.clk(clk),.rst_n(rst_n),.v_in(red_go),
                     .a(accy[0]),.b(accy[1]),.v_out(),.y(ry01));
    fp32_add u_rz01 (.clk(clk),.rst_n(rst_n),.v_in(red_go),
                     .a(accz[0]),.b(accz[1]),.v_out(),.y(rz01));
    fp32_add u_rx23 (.clk(clk),.rst_n(rst_n),.v_in(red_go),
                     .a(accx[2]),.b(accx[3]),.v_out(),.y(rx23));
    fp32_add u_ry23 (.clk(clk),.rst_n(rst_n),.v_in(red_go),
                     .a(accy[2]),.b(accy[3]),.v_out(),.y(ry23));
    fp32_add u_rz23 (.clk(clk),.rst_n(rst_n),.v_in(red_go),
                     .a(accz[2]),.b(accz[3]),.v_out(),.y(rz23));

    wire        red_v2;
    wire [31:0] rxs, rys, rzs;
    fp32_add u_rxs (.clk(clk),.rst_n(rst_n),.v_in(red_v1),
                    .a(rx01),.b(rx23),.v_out(red_v2),.y(rxs));
    fp32_add u_rys (.clk(clk),.rst_n(rst_n),.v_in(red_v1),
                    .a(ry01),.b(ry23),.v_out(),.y(rys));
    fp32_add u_rzs (.clk(clk),.rst_n(rst_n),.v_in(red_v1),
                    .a(rz01),.b(rz23),.v_out(),.y(rzs));

    // add the reduced total onto the body's stored velocity
    reg  [15:0] red_body;
    wire [15:0] red_body_d;
    delay_line #(.WIDTH(16), .DEPTH(6)) u_red_body
        (.clk(clk), .rst_n(rst_n), .d(red_body), .q(red_body_d));

    wire        fin_v;
    wire [31:0] fin_x, fin_y, fin_z;
    fp32_add u_fx (.clk(clk),.rst_n(rst_n),.v_in(red_v2),
                   .a(vx[red_body_d]),.b(rxs),.v_out(fin_v),.y(fin_x));
    fp32_add u_fy (.clk(clk),.rst_n(rst_n),.v_in(red_v2),
                   .a(vy[red_body_d]),.b(rys),.v_out(),.y(fin_y));
    fp32_add u_fz (.clk(clk),.rst_n(rst_n),.v_in(red_v2),
                   .a(vz[red_body_d]),.b(rzs),.v_out(),.y(fin_z));

    wire [15:0] fin_body;
    delay_line #(.WIDTH(16), .DEPTH(3)) u_fin_body
        (.clk(clk), .rst_n(rst_n), .d(red_body_d), .q(fin_body));

    always_ff @(posedge clk) begin
        if (rst_n && fin_v) begin
            vx[fin_body] <= fin_x;
            vy[fin_body] <= fin_y;
            vz[fin_body] <= fin_z;
        end
    end

    // ---------------- position integration ----------------------------------
    // px += dt * vx, done one body at a time. Three multiplies and three adds
    // per body; with only n_bodies iterations it is not on the critical path
    // (pair work is O(n^2), integration is O(n)).
    wire        int_mv;
    wire [31:0] int_mx, int_my, int_mz;
    fp32_mul u_ix (.clk(clk), .rst_n(rst_n), .v_in(state == S_INTEGRATE),
                   .a(dt_r), .b(vx[ii[15:0]]), .v_out(int_mv), .y(int_mx));
    fp32_mul u_iy (.clk(clk), .rst_n(rst_n), .v_in(state == S_INTEGRATE),
                   .a(dt_r), .b(vy[ii[15:0]]), .v_out(), .y(int_my));
    fp32_mul u_iz (.clk(clk), .rst_n(rst_n), .v_in(state == S_INTEGRATE),
                   .a(dt_r), .b(vz[ii[15:0]]), .v_out(), .y(int_mz));

    wire [15:0] int_idx;
    delay_line #(.WIDTH(16), .DEPTH(3)) u_int_idx
        (.clk(clk), .rst_n(rst_n), .d(ii[15:0]), .q(int_idx));

    wire        int_av;
    wire [31:0] int_ax, int_ay, int_az;
    fp32_add u_ax (.clk(clk), .rst_n(rst_n), .v_in(int_mv),
                   .a(px[int_idx]), .b(int_mx), .v_out(int_av), .y(int_ax));
    fp32_add u_ay (.clk(clk), .rst_n(rst_n), .v_in(int_mv),
                   .a(py[int_idx]), .b(int_my), .v_out(), .y(int_ay));
    fp32_add u_az (.clk(clk), .rst_n(rst_n), .v_in(int_mv),
                   .a(pz[int_idx]), .b(int_mz), .v_out(), .y(int_az));

    wire [15:0] int_widx;
    delay_line #(.WIDTH(16), .DEPTH(3)) u_int_widx
        (.clk(clk), .rst_n(rst_n), .d(int_idx), .q(int_widx));

    always_ff @(posedge clk) begin
        if (rst_n && int_av) begin
            px[int_widx] <= int_ax;
            py[int_widx] <= int_ay;
            pz[int_widx] <= int_az;
        end
    end

    // ---------------- DMA and sequencing ------------------------------------
    reg [31:0] inflight;      // pairs issued but not yet written back
    reg [31:0] int_pending;   // bodies issued to the integrator, not yet written

    assign m_rreq  = (state == S_LOAD_REQ);
    assign m_raddr = body_ptr + (li << 2);
    assign m_wreq  = (state == S_STORE_REQ);
    assign m_waddr = body_ptr + (li << 2);

    // Which word of the body array is being written back.
    wire [15:0] st_body = li[18:3];   // body index = word index >> 3
    wire [2:0]  st_word = li[2:0];
    assign m_wdata = (st_word == 3'd0) ? px[st_body] :
                     (st_word == 3'd1) ? py[st_body] :
                     (st_word == 3'd2) ? pz[st_body] :
                     (st_word == 3'd3) ? vx[st_body] :
                     (st_word == 3'd4) ? vy[st_body] :
                     (st_word == 3'd5) ? vz[st_body] :
                     (st_word == 3'd6) ? ms[st_body] : 32'd0;

    wire last_pair = (pi + 32'd1 >= n_bodies - 32'd1) && (pj + 32'd1 >= n_bodies);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            busy        <= 1'b0;
            done_r      <= 1'b0;
            err_r       <= 1'b0;
            irq_r       <= 1'b0;
            li          <= 32'd0;
            step        <= 32'd0;
            pi          <= 32'd0;
            pj          <= 32'd1;
            ii          <= 32'd0;
            iss_v       <= 1'b0;
            psel        <= 2'd0;
            red_go      <= 1'b0;
            acc_clear   <= 1'b1;
            red_body    <= 16'd0;
            pairs_cnt   <= 32'd0;
            cycles_cnt  <= 32'd0;
            inflight    <= 32'd0;
            int_pending <= 32'd0;
        end else begin
            iss_v     <= 1'b0;
            acc_clear <= 1'b0;
            if (busy) cycles_cnt <= cycles_cnt + 32'd1;
            // Gate the error flag on v_out. Latching pe_err unconditionally
            // catches the garbage that flows through the pipeline while it fills
            // and drains -- d2 = 0 from uninitialised deltas makes rsqrt flag a
            // bad input -- and raises a FALSE alarm on a perfectly correct run.
            // An error bit that cries wolf is worse than none, because a driver
            // would abort valid work.
            if (pe_v_out && pe_err) err_r <= 1'b1;

            // track outstanding work
            if (acc_v && inflight != 32'd0) inflight <= inflight - 32'd1;
            if (int_av   && int_pending != 32'd0) int_pending <= int_pending - 32'd1;

            if (abort_r) begin
                state <= S_IDLE;
                busy  <= 1'b0;
            end else case (state)

            S_IDLE: begin
                if (start_pulse) begin
                    busy       <= 1'b1;
                    done_r     <= 1'b0;
                    err_r      <= 1'b0;
                    irq_r      <= 1'b0;
                    li         <= 32'd0;
                    step       <= 32'd0;
                    psel       <= 2'd0;
                    acc_clear  <= 1'b1;
                    pairs_cnt  <= 32'd0;
                    cycles_cnt <= 32'd0;
                    state      <= S_LOAD_REQ;
                end
            end

            // ---- DMA the body array in -------------------------------------
            S_LOAD_REQ:  state <= S_LOAD_WAIT;
            S_LOAD_WAIT: if (m_rvalid) begin
                case (li[2:0])
                    3'd0: px[li[31:3]] <= m_rdata;
                    3'd1: py[li[31:3]] <= m_rdata;
                    3'd2: pz[li[31:3]] <= m_rdata;
                    3'd3: vx[li[31:3]] <= m_rdata;
                    3'd4: vy[li[31:3]] <= m_rdata;
                    3'd5: vz[li[31:3]] <= m_rdata;
                    3'd6: ms[li[31:3]] <= m_rdata;
                    default: ;                          // word 7 is padding
                endcase
                if (li + 32'd1 >= words_total) begin
                    li    <= 32'd0;
                    pi    <= 32'd0;
                    pj    <= 32'd1;
                    psel  <= 2'd0;
                    state <= (n_bodies < 32'd2) ? S_INTEGRATE : S_PAIR_ISSUE;
                end else begin
                    li    <= li + 32'd1;
                    state <= S_LOAD_REQ;
                end
            end

            // ---- stream every unique pair, one per cycle -------------------
            S_PAIR_ISSUE: begin
                // force on body pi from body pj, for every pj != pi
                a_px <= px[pi[15:0]]; a_py <= py[pi[15:0]]; a_pz <= pz[pi[15:0]];
                b_px <= px[pj[15:0]]; b_py <= py[pj[15:0]]; b_pz <= pz[pj[15:0]];
                // pe_pair's dv1 = d * (m2 * mag), which is the force on body 1
                // due to body 2, so m2 must carry the OTHER body's mass.
                a_m  <= ms[pj[15:0]]; b_m  <= ms[pj[15:0]];
                iss_i <= pi[15:0];    iss_j <= pj[15:0];
                iss_v <= 1'b1;
                psel  <= psel + 2'd1;          // round-robin the partials
                inflight  <= inflight + 32'd1;
                pairs_cnt <= pairs_cnt + 32'd1;

                // advance pj, skipping pj == pi
                if (pj + 32'd1 == pi)          state <= S_PAIR_ISSUE;
                if (pj + 32'd1 >= n_bodies) begin
                    state <= S_PAIR_DRAIN;
                end else begin
                    pj <= (pj + 32'd1 == pi) ? (pj + 32'd2) : (pj + 32'd1);
                    if ((pj + 32'd1 == pi) && (pj + 32'd2 >= n_bodies))
                        state <= S_PAIR_DRAIN;
                end
            end

            S_PAIR_DRAIN: if (inflight == 32'd0) begin
                red_body <= pi[15:0];
                red_go   <= 1'b1;              // one-cycle pulse
                state    <= S_REDUCE;
            end

            S_REDUCE: begin
                red_go <= 1'b0;
                state  <= S_REDUCE_WAIT;
            end

            S_REDUCE_WAIT: if (fin_v) begin
                acc_clear <= 1'b1;             // zero the partials for the next i
                if (pi + 32'd1 >= n_bodies) begin
                    ii    <= 32'd0;
                    state <= S_INTEGRATE;
                end else begin
                    pi    <= pi + 32'd1;
                    pj    <= (pi + 32'd1 == 32'd0) ? 32'd1 : 32'd0;
                    psel  <= 2'd0;
                    state <= S_PAIR_ISSUE;
                end
            end

            // ---- positions += dt * velocities ------------------------------
            S_INTEGRATE: begin
                int_pending <= int_pending + 32'd1;
                if (ii + 32'd1 >= n_bodies) begin
                    ii    <= 32'd0;
                    state <= S_STEP_DONE;
                end else begin
                    ii <= ii + 32'd1;
                end
            end

            // ---- next timestep, or DMA back out ----------------------------
            // Decide here, NOT in S_STORE_REQ. m_wreq is asserted in
            // S_STORE_REQ, so using that state to also decide "another timestep?"
            // emitted one spurious bus write per timestep -- the testbench caught
            // it as 67 words written back instead of 40.
            S_STEP_DONE: if (int_pending == 32'd0) begin
                if (step + 32'd1 < n_steps) begin
                    // another timestep: NO bus traffic at all, which is the
                    // entire point of carrying N_STEPS in the descriptor
                    step      <= step + 32'd1;
                    pi        <= 32'd0;
                    pj        <= 32'd1;
                    psel      <= 2'd0;
                    acc_clear <= 1'b1;
                    state     <= S_PAIR_ISSUE;
                end else begin
                    li    <= 32'd0;
                    state <= S_STORE_REQ;
                end
            end

            S_STORE_REQ: state <= S_STORE_WAIT;

            S_STORE_WAIT: if (m_wready) begin
                if (li + 32'd1 >= words_total) begin
                    state <= S_DONE;
                end else begin
                    li    <= li + 32'd1;
                    state <= S_STORE_REQ;
                end
            end

            S_DONE: begin
                busy   <= 1'b0;
                done_r <= 1'b1;
                if (irq_en) irq_r <= 1'b1;
                state  <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire

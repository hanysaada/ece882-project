// ============================================================================
// delay_line.sv — parameterised shift register for pipeline balancing
// ----------------------------------------------------------------------------
// In a pipelined datapath every value that is consumed LATER than it is produced
// must be held for exactly the right number of cycles. Getting one of those
// depths wrong silently mixes data from two different inputs, which is the most
// common bug in this style of design and does not announce itself: the circuit
// still produces plausible-looking numbers.
//
// Hand-rolling these shift registers inline is how such bugs happen -- and it is
// how one already happened in this project, when two always_ff blocks shared a
// loop variable. Doing it once, in one reviewed module, removes the whole class.
//
//   DEPTH = 0 passes the input straight through (useful when a generate loop
//           computes a depth that happens to be zero).
//
// LATENCY = DEPTH cycles, II = 1.
// ============================================================================
`default_nettype none

module delay_line #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 1
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire [WIDTH-1:0]      d,
    output wire [WIDTH-1:0]      q
);

    if (DEPTH == 0) begin : g_passthrough
        assign q = d;
    end else begin : g_regs
        reg [WIDTH-1:0] r [0:DEPTH-1];

        always_ff @(posedge clk) begin : p_shift
            integer i;
            if (!rst_n) begin
                for (i = 0; i < DEPTH; i = i + 1) r[i] <= {WIDTH{1'b0}};
            end else begin
                r[0] <= d;
                for (i = 1; i < DEPTH; i = i + 1) r[i] <= r[i-1];
            end
        end

        assign q = r[DEPTH-1];
    end

endmodule

`default_nettype wire

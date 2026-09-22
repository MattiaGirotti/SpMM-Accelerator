// ============================================================================
// Module: c_buffer
// Description: SCM Buffer Module for Output Matrix C (CSR SpMM for PULP).
//              Fixed multi-word assignment bug from multi-MAC output vector.
// ============================================================================

module c_buffer #(
    parameter int unsigned DATA_WIDTH_OUT  = 32,          // INT32 output width from MAC array
    parameter int unsigned NUM_MACS        = 4,           // Number of parallel output columns
    parameter int unsigned NUM_C_ROWS      = 32,          // Maximum number of storable C rows
    parameter int unsigned STREAM_WORD_BIT = 32,          // PULP Streamer word width
    parameter bit          REGISTERED_READ = 1,          // 1: Registered read (1 cycle), 0: Combinatorial
    parameter bit          USE_LATCHES     = 0           // 1: Use Clock Gating + Latches, 0: Flip-Flop
)(
    input  logic                                                clk_i,
    input  logic                                                rst_ni,
    input  logic                                                clear_i,

    // --- Write Interface (from Datapath MAC Array) ---
    input  logic                                                write_en_i,        // Row write enable
    input  logic [$clog2(NUM_C_ROWS)-1:0]                       write_row_addr_i,  // Address of C row to write
    input  logic unsigned [NUM_MACS-1:0][DATA_WIDTH_OUT-1:0]    wdata_i,           // Full row data from Datapath

    // --- Read Interface (to HWPE Streamer) ---
    input  logic [$clog2(NUM_C_ROWS)-1:0]                       read_row_addr_i,   // Row address to read
    input  logic [$clog2((NUM_MACS*DATA_WIDTH_OUT)/STREAM_WORD_BIT)-1:0] read_word_addr_i, // 32-bit word index inside row
    output logic [STREAM_WORD_BIT-1:0]                          rdata_c_o          // 32-bit output word to Streamer
);

    localparam int unsigned WORDS_PER_ROW = (NUM_MACS * DATA_WIDTH_OUT) / STREAM_WORD_BIT;

    // SCM Memory Matrix organized in Rows and 32-bit Words
    logic [NUM_C_ROWS-1:0][WORDS_PER_ROW-1:0][STREAM_WORD_BIT-1:0] mem_q;

    // Flatten input data vector to allow safe bit-slicing across streamer words
    logic [NUM_MACS*DATA_WIDTH_OUT-1:0] wdata_flat;
    assign wdata_flat = wdata_i;

    // Support signal for combinatorial read
    logic [STREAM_WORD_BIT-1:0] rdata_comb;
    assign rdata_comb = mem_q[read_row_addr_i][read_word_addr_i];

    // -------------------------------------------------------------------------
    // WRITE SIDE (Write Logic) (Datapath -> SCM)
    // -------------------------------------------------------------------------
    if (USE_LATCHES) begin : gen_latches
        // Latch + Clock Gating implementation for area saving (PULP RedMulE style)
        logic [NUM_C_ROWS-1:0] clk_w;

        for (genvar r = 0; r < NUM_C_ROWS; r++) begin : gen_rows_cg
            tc_clk_gating i_cg (
                .clk_i     (clk_i),
                .en_i      ((write_en_i && (write_row_addr_i == r)) || clear_i),
                .test_en_i ('0),
                .clk_o     (clk_w[r])
            );

            always_latch begin
                if (clk_w[r]) begin
                    if (clear_i) begin
                        for (int w = 0; w < WORDS_PER_ROW; w++) begin
                            mem_q[r][w] = '0;
                        end
                    end else begin
                        for (int w = 0; w < WORDS_PER_ROW; w++) begin
                            // Fixed: Explicit bit-slicing using flattened input vector
                            mem_q[r][w] = wdata_flat[w*STREAM_WORD_BIT +: STREAM_WORD_BIT];
                        end
                    end
                end
            end
        end
    end else begin : gen_flip_flops
        // Standard Flip-Flop-based implementation
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (~rst_ni) begin
                mem_q <= '0;
            end else if (clear_i) begin
                mem_q <= '0;
            end else if (write_en_i) begin
                for (int w = 0; w < WORDS_PER_ROW; w++) begin
                    // Fixed: Explicit bit-slicing using flattened input vector
                    mem_q[write_row_addr_i][w] <= wdata_flat[w*STREAM_WORD_BIT +: STREAM_WORD_BIT];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // READ SIDE (Read Logic) (SCM -> HWPE Streamer)
    // -------------------------------------------------------------------------
    if (REGISTERED_READ) begin : gen_reg_read
        // Read with 1 cycle latency
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (~rst_ni) begin
                rdata_c_o <= '0;
            end else if (clear_i) begin
                rdata_c_o <= '0;
            end else begin
                rdata_c_o <= rdata_comb;
            end
        end
    end else begin : gen_comb_read
        // Purely combinatorial read (0 cycles latency)
        assign rdata_c_o = rdata_comb;
    end

endmodule
// SCM Buffer Module for Column IDs (CSR SpMM Accelerators for PULP Cluster)
module colID_buffer #(
    parameter int unsigned DATA_WIDTH      = 8,           // INT8 (size of a single column ID)
    parameter int unsigned TOTAL_ID        = 64,          // Maximum total number of storable column IDs
    parameter int unsigned STREAM_WORD_BIT = 32,          // PULP Streamer word width
    parameter bit          REGISTERED_READ = 1,          // 1: Registered read (1 cycle latency), 0: Combinatorial (0 cycles)
    parameter bit          USE_LATCHES     = 0           // 1: Use Clock Gating + Latches (RedMulE style), 0: Flip-Flops
)(
    input  logic                                                clk_i,
    input  logic                                                rst_ni,
    input  logic                                                clear_i,

    // --- Write Interface (from HWPE Streamer) ---
    input  logic                                                write_en_i,          // Block write enable
    input  logic [$clog2(TOTAL_ID/(STREAM_WORD_BIT/DATA_WIDTH))-1:0] write_word_addr_i, // Address of the block to write
    input  logic [STREAM_WORD_BIT-1:0]                          wdata_i,             // Block data bus from Streamer (e.g., 32-bit)

    // --- Read Interface (to Datapath - 1 element at a time) ---
    input  logic [$clog2(TOTAL_ID)-1:0]                        read_addr_i,         // Global address of the single column ID (from 0 to TOTAL_ID-1)
    output logic unsigned [DATA_WIDTH-1:0]                      rdata_o,             // Single output column ID value (INT8)

    // --- Status Interface ---
    output logic                                                full_o               // High when all words have been written
);

    localparam int unsigned ELEMS_PER_WORD = STREAM_WORD_BIT / DATA_WIDTH;               // E.g., 32 / 8 = 4 elements per word
    localparam int unsigned NUM_WORDS      = TOTAL_ID / ELEMS_PER_WORD;                 // Total number of blocks/words

    // SCM memory matrix linear/block-structured for column IDs
    logic [NUM_WORDS-1:0][ELEMS_PER_WORD-1:0][DATA_WIDTH-1:0] mem_q;

    // Tracking written words to detect full status
    logic [NUM_WORDS-1:0] valid_mask_q;

    // Translation of global read address into internal coordinates [word][element]
    logic [$clog2(NUM_WORDS)-1:0]      r_word_idx;
    logic [$clog2(ELEMS_PER_WORD)-1:0] r_elem_idx;

    assign r_word_idx = read_addr_i / ELEMS_PER_WORD;
    assign r_elem_idx = read_addr_i % ELEMS_PER_WORD;

    // Support signal for the combinatorial read multiplexer
    logic signed [DATA_WIDTH-1:0] rdata_comb;
    assign rdata_comb = mem_q[r_word_idx][r_elem_idx];

    // Status output logic
    assign full_o = &valid_mask_q;

    // -------------------------------------------------------------------------
    // WRITE SIDE & VALID TRACKING (MEM-SCM)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            valid_mask_q <= '0;
        end else if (clear_i) begin
            valid_mask_q <= '0;
        end else if (write_en_i) begin
            valid_mask_q[write_word_addr_i] <= 1'b1;
        end
    end

    if (USE_LATCHES) begin : gen_latches
        // Latch + Clock Gating implementation for area saving (RedMulE style)
        logic [NUM_WORDS-1:0] clk_w;

        for (genvar w = 0; w < NUM_WORDS; w++) begin : gen_words_cg
            tc_clk_gating i_cg (
                .clk_i     (clk_i),
                .en_i      ((write_en_i && (write_word_addr_i == w)) || clear_i),
                .test_en_i ('0),
                .clk_o     (clk_w[w])
            );

            for (genvar e = 0; e < ELEMS_PER_WORD; e++) begin : gen_elems_latch
                always_latch begin
                    if (clk_w[w]) begin
                        if (clear_i) begin
                            mem_q[w][e] = '0;
                        end else begin
                            mem_q[w][e] = wdata_i[e*DATA_WIDTH +: DATA_WIDTH];
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
                for (int e = 0; e < ELEMS_PER_WORD; e++) begin
                    mem_q[write_word_addr_i][e] <= wdata_i[e*DATA_WIDTH +: DATA_WIDTH];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // READ SIDE (Read Logic) (SCM-Datapath)
    // -------------------------------------------------------------------------
    if (REGISTERED_READ) begin : gen_reg_read
        // Read with 1 cycle latency (recommended for high frequencies)
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (~rst_ni) begin
                rdata_o <= '0;
            end else if (clear_i) begin
                rdata_o <= '0;
            end else begin
                rdata_o <= rdata_comb;
            end
        end
    end else begin : gen_comb_read
        // Purely combinatorial read (0 cycles latency)
        assign rdata_o = rdata_comb;
    end

endmodule
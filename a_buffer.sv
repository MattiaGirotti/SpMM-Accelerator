// SCM Buffer Module for Non-Zero Values (CSR SpMM Accelerators for PULP Cluster)
module a_buffer #(
    parameter int unsigned DATA_WIDTH      = 8,           // INT8 (size of a single NNZ value)
    parameter int unsigned TOTAL_NNZ       = 64,          // Maximum total number of storable NNZ values
    parameter int unsigned STREAM_WORD_BIT = 32,          // PULP Streamer word width
    parameter bit          USE_LATCHES     = 0           // 1: Use Clock Gating + Latches (RedMulE style), 0: Flip-Flop
)(
    input  logic                                                clk_i,
    input  logic                                                rst_ni,
    input  logic                                                clear_i,

    // --- Write Interface (from HWPE Streamer) --- 
    input  logic                                                write_en_i,          // Block write enable 
    input  logic [$clog2(TOTAL_NNZ/(STREAM_WORD_BIT/DATA_WIDTH))-1:0] write_word_addr_i, // Address of the block to write 
    input  logic [STREAM_WORD_BIT-1:0]                          wdata_i,             // Block data bus from the Streamer (e.g., 32-bit) 

    // --- Read Interface (to Datapath - 1 element at a time) --- 
    input  logic [$clog2(TOTAL_NNZ)-1:0]                        read_addr_i,         // Global address of the single NNZ (from 0 to TOTAL_NNZ-1) 
    output logic unsigned [DATA_WIDTH-1:0]                      rdata_a_o           // Single output NNZ value (INT8) 
);

    localparam int unsigned ELEMS_PER_WORD = STREAM_WORD_BIT / DATA_WIDTH;               // E.g., 32 / 8 = 4 elements per word 
    localparam int unsigned NUM_WORDS      = TOTAL_NNZ / ELEMS_PER_WORD;                 // Total number of blocks/words 

    // Linear/block-structured SCM memory matrix for NNZ values 
    logic [NUM_WORDS-1:0][ELEMS_PER_WORD-1:0][DATA_WIDTH-1:0] mem_q;

    // Translation of the global read address into internal coordinates [word][element] 
    logic [$clog2(NUM_WORDS)-1:0]      r_word_idx;
    logic [$clog2(ELEMS_PER_WORD)-1:0] r_elem_idx;

    assign r_word_idx = read_addr_i / ELEMS_PER_WORD;
    assign r_elem_idx = read_addr_i % ELEMS_PER_WORD;
 
    assign rdata_a_o = mem_q[r_word_idx][r_elem_idx];

    if (USE_LATCHES) begin : gen_latches
        // Implementation based on Latch + Clock Gating for area saving (RedMulE style) 
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
        // Standard Flip-Flop based implementation 
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

endmodule
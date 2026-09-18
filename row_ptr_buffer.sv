// SCM Buffer Module for the Row Pointer Array (CSR SpMM)  
module row_ptr_buffer #(
    parameter int unsigned DATA_WIDTH      = 16,
    parameter int unsigned TOTAL_PTRS      = 65,
    parameter int unsigned STREAM_WORD_BIT = 32,
    parameter bit          REGISTERED_READ = 1,
    parameter bit          USE_LATCHES     = 0,
    // Derived parameters added to size the ports  
    parameter int unsigned ELEMS_PER_WORD  = STREAM_WORD_BIT / DATA_WIDTH,
    parameter int unsigned NUM_WORDS       = (TOTAL_PTRS + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD
)(
    input  logic                               clk_i,
    input  logic                               rst_ni,
    input  logic                               clear_i,

    // --- Write Interface ---  
    input  logic                               write_en_i,          
    input  logic [$clog2(NUM_WORDS)-1:0]       write_word_addr_i,
    input  logic [STREAM_WORD_BIT-1:0]         wdata_i,             

    // --- Read Interface ---  
    input  logic [$clog2(TOTAL_PTRS-1)-1:0]    read_row_idx_i,      
    output logic [DATA_WIDTH-1:0]              rdata_start_o,       
    output logic [DATA_WIDTH-1:0]              rdata_end_o         
);

    // Linear/block-structured SCM memory array  
    logic [NUM_WORDS-1:0][ELEMS_PER_WORD-1:0][DATA_WIDTH-1:0] mem_q;

    // Translation of row index to coordinates for the first element (row_ptr[i])  
    logic [$clog2(NUM_WORDS)-1:0]      r1_word_idx;
    logic [$clog2(ELEMS_PER_WORD)-1:0] r1_elem_idx;

    assign r1_word_idx = read_row_idx_i / ELEMS_PER_WORD;
    assign r1_elem_idx = read_row_idx_i % ELEMS_PER_WORD;

    // Translation of row index to coordinates for the second element (row_ptr[i+1])  
    logic [$clog2(NUM_WORDS)-1:0]      r2_word_idx;
    logic [$clog2(ELEMS_PER_WORD)-1:0] r2_elem_idx;
    logic [$clog2(TOTAL_PTRS)-1:0]     next_row_idx;

    assign next_row_idx = read_row_idx_i + 1;
    assign r2_word_idx  = next_row_idx / ELEMS_PER_WORD;
    assign r2_elem_idx  = next_row_idx % ELEMS_PER_WORD;

    // Support signals for combinational read multiplexers  
    logic [DATA_WIDTH-1:0] rdata_start_comb;
    logic [DATA_WIDTH-1:0] rdata_end_comb;

    assign rdata_start_comb = mem_q[r1_word_idx][r1_elem_idx];
    assign rdata_end_comb   = mem_q[r2_word_idx][r2_elem_idx];

    if (USE_LATCHES) begin : gen_latches
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
                        end else if (w * ELEMS_PER_WORD + e < TOTAL_PTRS) begin
                            mem_q[w][e] = wdata_i[e*DATA_WIDTH +: DATA_WIDTH];
                        end
                    end
                end
            end
        end
    end else begin : gen_flip_flops
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (~rst_ni) begin
                mem_q <= '0;
            end else if (clear_i) begin
                mem_q <= '0;
            end else if (write_en_i) begin
                for (int e = 0; e < ELEMS_PER_WORD; e++) begin
                    if (write_word_addr_i * ELEMS_PER_WORD + e < TOTAL_PTRS) begin
                        mem_q[write_word_addr_i][e] <= wdata_i[e*DATA_WIDTH +: DATA_WIDTH];
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // READ SIDE (Read Logic) (SCM-Datapath)  
    // -------------------------------------------------------------------------
    if (REGISTERED_READ) begin : gen_reg_read
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (~rst_ni) begin
                rdata_start_o <= '0;
                rdata_end_o   <= '0;
            end else if (clear_i) begin
                rdata_start_o <= '0;
                rdata_end_o   <= '0;
            end else begin
                rdata_start_o <= rdata_start_comb;
                rdata_end_o   <= rdata_end_comb;
            end
        end
    end else begin : gen_comb_read
        assign rdata_start_o = rdata_start_comb;
        assign rdata_end_o   = rdata_end_comb;
    end

endmodule
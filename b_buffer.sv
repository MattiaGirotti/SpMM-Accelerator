// SCM Buffer Module for Dense Matrix B (SpMM Accelerators for PULP Cluster) 
module b_buffer #(
    parameter int unsigned DATA_WIDTH      = 8,           // INT8 
    parameter int unsigned NUM_MACS        = 4,           // Number of parallel B columns (MACs) 
    parameter int unsigned NUM_B_ROWS      = 32,          // Maximum number of storable B rows 
    parameter int unsigned STREAM_WORD_BIT = 32,          // PULP Streamer word width 
    parameter bit          REGISTERED_READ = 1,          // 1: Registered read (1 cycle latency), 0: Combinatorial (0 cycles) 
    parameter bit          USE_LATCHES     = 0           // 1: Use Clock Gating + Latches (RedMulE style) 
)(
    input  logic                                                clk_i,
    input  logic                                                rst_ni,
    input  logic                                                clear_i,

    // --- Write Interface (from HWPE Streamer) --- 
    input  logic                                                write_en_i,        // Write enable signal 
    input  logic [$clog2(NUM_B_ROWS)-1:0]                       write_row_addr_i,  // Address of the B row to write 
    input  logic [$clog2((NUM_MACS*DATA_WIDTH)/STREAM_WORD_BIT)-1:0] write_word_addr_i, // Address of the word to write inside the B row 
    input  logic [STREAM_WORD_BIT-1:0]                          wdata_i,           // Write data bus (from Streamer) 

    // --- Read Interface (to Datapath MAC Array) --- 
    input  logic [$clog2(NUM_B_ROWS)-1:0]                       read_row_addr_i,   // Address of the B row to read 
    output logic unsigned [NUM_MACS-1:0][DATA_WIDTH-1:0]        rdata_b_o,         // Read data bus (to Datapath MAC Array) 

    // --- Status Interface ---
    output logic                                                full_o             // High when all rows and words are written
);

    localparam int unsigned WORDS_PER_ROW = (NUM_MACS * DATA_WIDTH) / STREAM_WORD_BIT; 
    localparam int unsigned ELEMS_PER_WORD = STREAM_WORD_BIT / DATA_WIDTH; 

    // SCM Memory Matrix 
    logic [NUM_B_ROWS-1:0][NUM_MACS-1:0][DATA_WIDTH-1:0] mem_q; 

    // Tracking written words across all rows and word slots
    logic [NUM_B_ROWS-1:0][WORDS_PER_ROW-1:0] valid_mask_q;

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
            valid_mask_q[write_row_addr_i][write_word_addr_i] <= 1'b1;
        end
    end

    if (USE_LATCHES) begin : gen_latches 
        // Latch + Clock Gating implementation for area saving (PULP) 
        logic [NUM_B_ROWS-1:0][WORDS_PER_ROW-1:0] clk_w; 

        for (genvar r = 0; r < NUM_B_ROWS; r++) begin : gen_rows_cg 
            for (genvar w = 0; w < WORDS_PER_ROW; w++) begin : gen_words_cg 
                tc_clk_gating i_cg ( 
                    .clk_i     (clk_i), 
                    .en_i      ((write_en_i && (write_row_addr_i == r) && (write_word_addr_i == w)) || clear_i), 
                    .test_en_i ('0), 
                    .clk_o     (clk_w[r][w]) 
                );

                always_latch begin 
                    if (clk_w[r][w]) begin 
                        if (clear_i) begin 
                            for (int e = 0; e < ELEMS_PER_WORD; e++) begin 
                                mem_q[r][w*ELEMS_PER_WORD + e] = '0; 
                            end
                        end else begin
                            for (int e = 0; e < ELEMS_PER_WORD; e++) begin 
                                mem_q[r][w*ELEMS_PER_WORD + e] = wdata_i[e*DATA_WIDTH +: DATA_WIDTH]; 
                            end
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
                    mem_q[write_row_addr_i][write_word_addr_i * ELEMS_PER_WORD + e] <= wdata_i[e*DATA_WIDTH +: DATA_WIDTH]; 
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // READ SIDE (Read Logic) (SCM-Datapath) 
    // -------------------------------------------------------------------------
    if (REGISTERED_READ) begin : gen_reg_read 
        // Read with 1 cycle latency (recommended for high f_MAX) 
        always_ff @(posedge clk_i or negedge rst_ni) begin 
            if (~rst_ni) begin 
                rdata_b_o <= '0; 
            end else if (clear_i) begin
                rdata_b_o <= '0;
            end else begin
                rdata_b_o <= mem_q[read_row_addr_i]; 
            end
        end
    end else begin : gen_comb_read 
        // Purely combinatorial read (0 cycles latency) 
        assign rdata_b_o = mem_q[read_row_addr_i]; 
    end

endmodule
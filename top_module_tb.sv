`timescale 1ns/1ps

module top_module_tb;

    // --- Module Parameters ---
    parameter int unsigned DATA_WIDTH      = 8;
    parameter int unsigned NUM_MACS        = 16;
    parameter int unsigned NUM_ROWS        = 16;
    parameter int unsigned TOTAL_NNZ       = 64;
    parameter int unsigned TOTAL_PTRS      = 65;
    parameter int unsigned STREAM_WORD_BIT = 32;
    parameter int unsigned DATA_WIDTH_OUT  = 32;
    parameter bit          USE_LATCHES     = 0;

    localparam int unsigned ROW_PTR_ELEMS_PER_WORD = STREAM_WORD_BIT / DATA_WIDTH;
    localparam int unsigned ROW_PTR_NUM_WORDS      = (TOTAL_PTRS + ROW_PTR_ELEMS_PER_WORD - 1) / ROW_PTR_ELEMS_PER_WORD;
    localparam int unsigned B_NUM_WORDS_PER_ROW    = (NUM_MACS * DATA_WIDTH) / STREAM_WORD_BIT;

    // --- Testbench Signals ---
    logic clk_i;
    logic rst_ni;
    logic clear_i;

    // Accelerator Control Signals
    logic start_i;
    logic busy_o;
    logic done_o;

    // a_buffer write port
    logic                                                             a_write_en_i;
    logic [$clog2(TOTAL_NNZ/(STREAM_WORD_BIT/DATA_WIDTH))-1:0]       a_write_word_addr_i;
    logic [STREAM_WORD_BIT-1:0]                                       a_wdata_i;

    // b_buffer write port
    logic                                                             b_write_en_i;
    logic [$clog2(NUM_ROWS)-1:0]                                      b_write_row_addr_i;
    logic [$clog2((NUM_MACS*DATA_WIDTH)/STREAM_WORD_BIT)-1:0]        b_write_word_addr_i;
    logic [STREAM_WORD_BIT-1:0]                                       b_wdata_i;

    // colID_buffer write port
    logic                                                             col_id_write_en_i;
    logic [$clog2(TOTAL_NNZ/(STREAM_WORD_BIT/DATA_WIDTH))-1:0]       col_id_write_word_addr_i;
    logic [STREAM_WORD_BIT-1:0]                                       col_id_wdata_i;

    // row_ptr_buffer write port
    logic                                                             row_ptr_write_en_i;
    logic [$clog2(ROW_PTR_NUM_WORDS)-1:0]                            row_ptr_write_word_addr_i;
    logic [STREAM_WORD_BIT-1:0]                                       row_ptr_wdata_i;

    // c_buffer read port
    logic [$clog2(NUM_ROWS)-1:0]                                      c_read_row_addr_i;
    logic [$clog2((NUM_MACS*DATA_WIDTH_OUT)/STREAM_WORD_BIT)-1:0]     c_read_word_addr_i;
    logic [STREAM_WORD_BIT-1:0]                                       c_rdata_o;

    // --- Clock Generation (100 MHz) ---
    always #5 clk_i = ~clk_i;

    // --- Top Module Instantiation ---
    top_module #(
        .DATA_WIDTH      (DATA_WIDTH),
        .NUM_MACS        (NUM_MACS),
        .NUM_ROWS        (NUM_ROWS),
        .TOTAL_NNZ       (TOTAL_NNZ),
        .TOTAL_PTRS      (TOTAL_PTRS),
        .STREAM_WORD_BIT (STREAM_WORD_BIT),
        .DATA_WIDTH_OUT  (DATA_WIDTH_OUT),
        .USE_LATCHES     (USE_LATCHES)
    ) u_top (
        .clk_i                      (clk_i),
        .rst_ni                     (rst_ni),
        .clear_i                    (clear_i),
        .start_i                    (start_i),
        .busy_o                     (busy_o),
        .done_o                     (done_o),
        .a_write_en_i               (a_write_en_i),
        .a_write_word_addr_i        (a_write_word_addr_i),
        .a_wdata_i                  (a_wdata_i),
        .b_write_en_i               (b_write_en_i),
        .b_write_row_addr_i         (b_write_row_addr_i),
        .b_write_word_addr_i        (b_write_word_addr_i),
        .b_wdata_i                  (b_wdata_i),
        .col_id_write_en_i          (col_id_write_en_i),
        .col_id_write_word_addr_i   (col_id_write_word_addr_i),
        .col_id_wdata_i             (col_id_wdata_i),
        .row_ptr_write_en_i         (row_ptr_write_en_i),
        .row_ptr_write_word_addr_i  (row_ptr_write_word_addr_i),
        .row_ptr_wdata_i            (row_ptr_wdata_i),
        .c_read_row_addr_i          (c_read_row_addr_i),
        .c_read_word_addr_i         (c_read_word_addr_i),
        .c_rdata_o                  (c_rdata_o)
    );

    // --- Data Loading Task ---
    task load_buffers();
        // Array di supporto per memorizzare e stampare la matrice B
        logic [STREAM_WORD_BIT-1:0] b_matrix_shadow [NUM_ROWS][B_NUM_WORDS_PER_ROW];
        begin
            $display("[TB] Starting data loading into SCM Buffers...");

           // 1. Loading ROW POINTERS (17 pointers for 16 rows: [0, 2, 2, 6, 8, 10, 11, 12, 15, 16, 18, 18, 20, 23, 24, 26, 28])
            row_ptr_write_en_i        = 1'b1;
            
            // Word 0: R0..R3 -> [0, 2, 2, 6]
            row_ptr_write_word_addr_i = 'd0;
            row_ptr_wdata_i           = {8'd6, 8'd2, 8'd2, 8'd0}; #10;
            
            // Word 1: R4..R7 -> [12, 11, 10, 8]
            row_ptr_write_word_addr_i = 'd1;
            row_ptr_wdata_i           = {8'd12, 8'd11, 8'd10, 8'd8}; #10;
            
            // Word 2: R8..R11 -> [18, 18, 16, 15]
            row_ptr_write_word_addr_i = 'd2;
            row_ptr_wdata_i           = {8'd18, 8'd18, 8'd16, 8'd15}; #10;

            // Word 3: R12..R15 -> [26, 24, 23, 20]
            row_ptr_write_word_addr_i = 'd3;
            row_ptr_wdata_i           = {8'd26, 8'd24, 8'd23, 8'd20}; #10;

            // Word 4: Final Ptr -> [28]
            row_ptr_write_word_addr_i = 'd4;
            row_ptr_wdata_i           = {24'd0, 8'd28}; #10;
            
            row_ptr_write_en_i        = 1'b0;

            // 2. Loading DENSE MATRIX B (16x16) - Generazione Randomica e Scrittura Buffer
            b_write_en_i = 1'b1;
            for (int r = 0; r < NUM_ROWS; r++) begin
                b_write_row_addr_i = r[$clog2(NUM_ROWS)-1:0];
                for (int w = 0; w < B_NUM_WORDS_PER_ROW; w++) begin
                    b_write_word_addr_i = w[$clog2(B_NUM_WORDS_PER_ROW)-1:0];
                    b_wdata_i           = $urandom(); // Genera un valore casuale a 32 bit
                    b_matrix_shadow[r][w] = b_wdata_i; // Salvataggio per la stampa
                    #10;
                end
            end
            b_write_en_i = 1'b0;

            // Stampa a video della Matrice B 16x16 in formato decimale
            $display("==================================================");
            $display("       RANDOM MATRIX B GENERATED (16x16)          ");
            $display("==================================================");
            for (int r = 0; r < NUM_ROWS; r++) begin
                $write("Row %2d -> [", r);
                for (int w = 0; w < B_NUM_WORDS_PER_ROW; w++) begin
                    // Estrae i 4 elementi da 8 bit all'interno di ciascuna parola da 32 bit
                    $write("%3d %3d %3d %3d", 
                           b_matrix_shadow[r][w][7:0], 
                           b_matrix_shadow[r][w][15:8], 
                           b_matrix_shadow[r][w][23:16], 
                           b_matrix_shadow[r][w][31:24]);
                    if (w < B_NUM_WORDS_PER_ROW - 1) $write(" | ");
                end
                $display("]");
            end
            $display("==================================================\n");

            // 3. Loading NON-ZERO VALUES FOR MATRIX A (28 total elements)
            a_write_en_i        = 1'b1;
            a_write_word_addr_i = '0; a_wdata_i = {8'd1, 8'd4, 8'd5, 8'd3}; #10;
            a_write_word_addr_i = 'd1; a_wdata_i = {8'd8, 8'd6, 8'd2, 8'd7}; #10;
            a_write_word_addr_i = 'd2; a_wdata_i = {8'd10, 8'd5, 8'd2, 8'd1}; #10;
            a_write_word_addr_i = 'd3; a_wdata_i = {8'd1, 8'd2, 8'd3, 8'd2}; #10;
            a_write_word_addr_i = 'd4; a_wdata_i = {8'd20, 8'd10, 8'd3, 8'd3}; #10;
            a_write_word_addr_i = 'd5; a_wdata_i = {8'd5, 8'd1, 8'd2, 8'd1}; #10;
            a_write_word_addr_i = 'd6; a_wdata_i = {8'd4, 8'd4, 8'd2, 8'd2}; #10;
            a_write_en_i        = 1'b0;

            // 4. Loading COLID FOR MATRIX A
            col_id_write_en_i        = 1'b1;
            col_id_write_word_addr_i = '0; col_id_wdata_i = {8'd1, 8'd0, 8'd2, 8'd0}; #10;
            col_id_write_word_addr_i = 'd1; col_id_wdata_i = {8'd4, 8'd5, 8'd3, 8'd2}; #10;
            col_id_write_word_addr_i = 'd2; col_id_wdata_i = {8'd4, 8'd4, 8'd7, 8'd6}; #10;
            col_id_write_word_addr_i = 'd3; col_id_wdata_i = {8'd10, 8'd6, 8'd5, 8'd7}; #10;
            col_id_write_word_addr_i = 'd4; col_id_wdata_i = {8'd12, 8'd13, 8'd15, 8'd11}; #10;
            col_id_write_word_addr_i = 'd5; col_id_wdata_i = {8'd7, 8'd14, 8'd9, 8'd8}; #10;
            col_id_write_word_addr_i = 'd6; col_id_wdata_i = {8'd6, 8'd3, 8'd1, 8'd10}; #10;
            col_id_write_en_i        = 1'b0;

            $display("[TB] Data loading completed.\n");
        end
    endtask

    // --- Main Test Sequence ---
    initial begin
        clk_i   = 0;
        rst_ni  = 0;
        clear_i = 0;
        start_i = 0;

        a_write_en_i          = 0; a_write_word_addr_i        = 0; a_wdata_i   = 0;
        b_write_en_i          = 0; b_write_row_addr_i         = 0; b_write_word_addr_i = 0; b_wdata_i = 0;
        col_id_write_en_i     = 0; col_id_write_word_addr_i   = 0; col_id_wdata_i = 0;
        row_ptr_write_en_i    = 0; row_ptr_write_word_addr_i  = 0; row_ptr_wdata_i = 0;

        c_read_row_addr_i     = 0;
        c_read_word_addr_i    = 0;

        // Reset
        #20;
        rst_ni = 1;
        #10;

        // Buffer Writing
        load_buffers();

        // Start Execution
        #20;
        start_i = 1'b1;
        #10;
        start_i = 1'b0;

        // Wait for Completion
        wait(done_o == 1'b1);
        #10;

        // Display and Verify C Results
        $display("==================================================");
        $display("           FINAL MATRIX C RESULTS                 ");
        $display("==================================================");
        
        for (int r = 0; r < NUM_ROWS; r++) begin
            logic [31:0] val [16];
            
            c_read_row_addr_i = r;
            
            for (int c = 0; c < 16; c++) begin
                c_read_word_addr_i = c; #10;
                val[c] = c_rdata_o;
            end

            $display("Row %2d -> [%3d %3d %3d %3d | %3d %3d %3d %3d | %3d %3d %3d %3d | %3d %3d %3d %3d]", 
                     r, val[0], val[1], val[2], val[3], val[4], val[5], val[6], val[7], 
                        val[8], val[9], val[10], val[11], val[12], val[13], val[14], val[15]);
        end
        $display("==================================================\n");

        #50;
        $finish;
    end

endmodule
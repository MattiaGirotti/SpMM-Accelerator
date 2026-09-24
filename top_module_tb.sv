`timescale 1ns/1ps

module top_module_tb;

    // --- Module Parameters ---
    parameter int unsigned DATA_WIDTH      = 8;
    parameter int unsigned NUM_MACS        = 4;
    parameter int unsigned NUM_ROWS        = 4;
    parameter int unsigned TOTAL_NNZ       = 64;
    parameter int unsigned TOTAL_PTRS      = 65;
    parameter int unsigned STREAM_WORD_BIT = 32;
    parameter int unsigned DATA_WIDTH_OUT  = 32;
    parameter bit          USE_LATCHES     = 0;

    localparam int unsigned ROW_PTR_ELEMS_PER_WORD = STREAM_WORD_BIT / DATA_WIDTH;
    localparam int unsigned ROW_PTR_NUM_WORDS      = (TOTAL_PTRS + ROW_PTR_ELEMS_PER_WORD - 1) / ROW_PTR_ELEMS_PER_WORD;

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
        begin
            $display("[TB] Starting data loading into SCM Buffers...");

            // 1. Loading ROW POINTERS
            // PtrStart/End for the 4 rows: [0, 2, 2, 6, 8]
            row_ptr_write_en_i        = 1'b1;
            row_ptr_write_word_addr_i = '0;
            // Byte0=0 (Start Row0), Byte1=2 (Start Row1), Byte2=2 (Start Row2), Byte3=6 (Start Row3)
            row_ptr_wdata_i           = {8'd6, 8'd2, 8'd2, 8'd0}; #10;
            row_ptr_write_word_addr_i = 'd1;
            // Byte0=8 (End Row3)
            row_ptr_wdata_i           = {24'd0, 8'd8}; #10;
            row_ptr_write_en_i        = 1'b0;

            // 2. Loading DENSE MATRIX B (4x4)
            // B = [[1, 2, 3, 4],
            //      [5, 6, 7, 8],
            //      [2, 1, 2, 3],
            //      [4, 1, 2, 5]]
            b_write_en_i        = 1'b1;
            b_write_word_addr_i = '0;

            b_write_row_addr_i  = 2'd0; b_wdata_i = {8'd4, 8'd3, 8'd2, 8'd1}; #10; // Row 0
            b_write_row_addr_i  = 2'd1; b_wdata_i = {8'd8, 8'd7, 8'd6, 8'd5}; #10; // Row 1
            b_write_row_addr_i  = 2'd2; b_wdata_i = {8'd3, 8'd2, 8'd1, 8'd2}; #10; // Row 2
            b_write_row_addr_i  = 2'd3; b_wdata_i = {8'd5, 8'd2, 8'd1, 8'd4}; #10; // Row 3
            b_write_en_i        = 1'b0;

            // 3. Loading NON-ZERO VALUES FOR MATRIX A (8 total elements)
            // Word 0 (NNZ 0..3): Row0(3, 5), Row2(4, 1)
            // Word 1 (NNZ 4..7): Row2(7, 2), Row3(6, 8)
            a_write_en_i        = 1'b1;
            a_write_word_addr_i = '0; a_wdata_i = {8'd1, 8'd4, 8'd5, 8'd3}; #10;
            a_write_word_addr_i = 'd1; a_wdata_i = {8'd8, 8'd6, 8'd2, 8'd7}; #10;
            a_write_en_i        = 1'b0;

            // 4. Loading COLID FOR MATRIX A
            // Word 0 (NNZ 0..3): Row0(col 0, col 2), Row2(col 0, col 1)
            // Word 1 (NNZ 4..7): Row2(col 2, col 3), Row3(col 2, col 3)
            col_id_write_en_i        = 1'b1;
            col_id_write_word_addr_i = '0; col_id_wdata_i = {8'd1, 8'd0, 8'd2, 8'd0}; #10;
            col_id_write_word_addr_i = 'd1; col_id_wdata_i = {8'd3, 8'd2, 8'd3, 8'd2}; #10;
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
            logic [31:0] val0, val1, val2, val3;
            
            c_read_row_addr_i = r;
            
            c_read_word_addr_i = 0; #10; val0 = c_rdata_o;
            c_read_word_addr_i = 1; #10; val1 = c_rdata_o;
            c_read_word_addr_i = 2; #10; val2 = c_rdata_o;
            c_read_word_addr_i = 3; #10; val3 = c_rdata_o;

            $display("Row %0d -> [Col0: %3d | Col1: %3d | Col2: %3d | Col3: %3d]", 
                     r, val0, val1, val2, val3);
        end
        $display("==================================================\n");

        #50;
        $finish;
    end

endmodule
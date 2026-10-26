`timescale 1ns/1ps

module top_module_tb;

    // --- Module Parameters ---
    parameter int unsigned DATA_WIDTH      = 8;
    parameter int unsigned NUM_MACS        = 16;
    parameter int unsigned NUM_ROWS        = 16;
    parameter int unsigned TOTAL_NNZ       = 64;  // Capacità massima statica del buffer SCM
    parameter int unsigned TOTAL_PTRS      = 17;  // 16 righe + 1
    parameter int unsigned STREAM_WORD_BIT = 128; // 128-bit bus width
    parameter int unsigned DATA_WIDTH_OUT  = 8;   // 8-bit output
    parameter bit          USE_LATCHES     = 0;

    localparam int unsigned ROW_PTR_ELEMS_PER_WORD = STREAM_WORD_BIT / DATA_WIDTH; // 128 / 8 = 16
    localparam int unsigned ROW_PTR_NUM_WORDS      = (TOTAL_PTRS + ROW_PTR_ELEMS_PER_WORD - 1) / ROW_PTR_ELEMS_PER_WORD; // 2 parole

    // --- Testbench Signals ---
    logic clk_i;
    logic rst_ni;
    logic clear_i;

    // Streamer Control & Status
    logic start_i;
    logic done_o;

    // Base Addresses & Lengths configuration
    logic [31:0] a_base_addr_i;
    logic [31:0] col_id_base_addr_i;
    logic [31:0] row_ptr_base_addr_i;
    logic [31:0] b_base_addr_i;
    logic [31:0] c_base_addr_i;

    logic [15:0] row_ptr_num_words_i;
    logic [15:0] b_num_words_i;
   
    // --- TCDM Interface Instantiation (DW = 128-bit) ---
    hci_core_intf #(.DW(128), .AW(32)) tcdm_if (.clk(clk_i));

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
        .clk_i               (clk_i),
        .rst_ni              (rst_ni),
        .clear_i             (clear_i),
        .start_i             (start_i),
        .done_o              (done_o),
        .tcdm_master         (tcdm_if),
        
        .row_ptr_base_addr_i (row_ptr_base_addr_i),
        .b_base_addr_i       (b_base_addr_i),
        .a_base_addr_i       (a_base_addr_i),
        .col_id_base_addr_i  (col_id_base_addr_i),
        .c_base_addr_i       (c_base_addr_i),

        .row_ptr_num_words_i (row_ptr_num_words_i),
        .b_num_words_i       (b_num_words_i)
    );

    // --- Behavioral TCDM Memory Model (128-bit wide) ---
    logic [127:0] tcdm_memory [0:8191];

    initial begin
        for (int i = 0; i < 8191; i++) begin
            tcdm_memory[i] = 128'h0;
        end
    end

    // --- Gestione TCDM con Grant Combinazionale ---
    assign tcdm_if.gnt = tcdm_if.req;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            tcdm_if.r_valid <= 1'b0;
            tcdm_if.r_data  <= '0;
        end else begin
            tcdm_if.r_valid <= 1'b0;

            if (tcdm_if.req) begin
                if (tcdm_if.wen) begin
                    tcdm_if.r_data  <= tcdm_memory[tcdm_if.add[31:4]];
                    tcdm_if.r_valid <= 1'b1;
                end else begin
                    tcdm_memory[tcdm_if.add[31:4]] <= tcdm_if.data;
                end
            end
        end
    end

    // =========================================================================
    // TASK 1: Popolamento TCDM per la PRIMA RUN (es. 26 NNZ totali)
    // =========================================================================
    task populate_tcdm_memory_run1();
        int addr_offset;
        begin
            $display("--------------------------------------------------");
            $display("[TB] Pre-loading TCDM Memory for RUN 1...");
            $display("--------------------------------------------------");

            row_ptr_base_addr_i = 32'h0000_1000;
            b_base_addr_i       = 32'h0000_2000;
            a_base_addr_i       = 32'h0000_3000;
            col_id_base_addr_i  = 32'h0000_4000;
            c_base_addr_i       = 32'h0000_5000;

            row_ptr_num_words_i = ROW_PTR_NUM_WORDS; // 2 parole
            b_num_words_i       = NUM_ROWS;          // 16 parole (1 per riga)

            // 1. Caricamento Row Pointers (L'ultimo elemento indica 26 NNZ)
            addr_offset = row_ptr_base_addr_i >> 4;
            tcdm_memory[addr_offset + 0] = {
                8'd26, 8'd24, 8'd23, 8'd20, 
                8'd18, 8'd18, 8'd16, 8'd15, 
                8'd12, 8'd11, 8'd10, 8'd6, 
                8'd3,  8'd2,  8'd2,  8'd0
            };
            tcdm_memory[addr_offset + 1] = {112'd0, 8'd26}; // Ultimo puntatore = 26 NNZ

            // 2. Caricamento Matrice B
            addr_offset = b_base_addr_i >> 4;
            for (int r = 0; r < NUM_ROWS; r++) begin
                tcdm_memory[addr_offset + r] = {
                    8'($urandom() % 10 + 1), 8'($urandom() % 10 + 1), 8'($urandom() % 10 + 1), 8'($urandom() % 10 + 1),
                    8'($urandom() % 10 + 1), 8'($urandom() % 10 + 1), 8'($urandom() % 10 + 1), 8'($urandom() % 10 + 1),
                    8'($urandom() % 10 + 1), 8'($urandom() % 10 + 1), 8'($urandom() % 10 + 1), 8'($urandom() % 10 + 1),
                    8'($urandom() % 10 + 1), 8'($urandom() % 10 + 1), 8'($urandom() % 10 + 1), 8'($urandom() % 10 + 1)
                };
            end

             // --- STAMPA DELLA MATRICE B IN FORMATO DECIMALE ---
            $display("==================================================");
            $display("    GENERATED RANDOM MATRIX B1 (16x16, INT8)       ");
            $display("==================================================");
            for (int r = 0; r < NUM_ROWS; r++) begin
                logic [127:0] b_row_val;
                b_row_val = tcdm_memory[addr_offset + r];
                $write("Row %2d -> [", r);
                // Stampa i 16 elementi decimali separati da virgola
                for (int e = 15; e >= 0; e--) begin
                    $write("%3d", b_row_val[e*8 +: 8]);
                    if (e > 0) $write(", ");
                end
                $display("]");
            end
            $display("==================================================\n");

            // 3. Caricamento Non-Zero Values A (26 elementi)
            addr_offset = a_base_addr_i >> 4;
            tcdm_memory[addr_offset + 0] = {
                8'd6, 8'd4, 8'd3, 8'd2, 
                8'd2, 8'd8, 8'd1, 8'd5, 
                8'd10, 8'd11, 8'd10, 8'd6, 
                8'd1,  8'd2,  8'd3,  8'd4
            };
            tcdm_memory[addr_offset + 1] = {
                80'd0,
                8'd7, 8'd9, 8'd3, 8'd2,
                8'd1, 8'd6, 8'd7, 8'd1,
                8'd2, 8'd8
            };

            // 4. Caricamento Col IDs (26 ID)
            addr_offset = col_id_base_addr_i >> 4;
            tcdm_memory[addr_offset + 0] = {
                8'd6, 8'd14, 8'd3, 8'd2, 
                8'd2, 8'd8, 8'd11, 8'd15, 
                8'd10, 8'd11, 8'd10, 8'd6, 
                8'd1,  8'd2,  8'd3,  8'd4
            };
            tcdm_memory[addr_offset + 1] = {
                80'd0,
                8'd7, 8'd9, 8'd3, 8'd2,
                8'd15, 8'd6, 8'd7, 8'd11,
                8'd2, 8'd8
            };

            $display("[TB] RUN 1 Data Loaded Successfully.\n");
        end
    endtask

    // =========================================================================
    // TASK 2: Popolamento TCDM per la SECONDA RUN (es. 20 NNZ totali, struttura diversa)
    // =========================================================================
    task populate_tcdm_memory_run2();
        int addr_offset;
        begin
            $display("--------------------------------------------------");
            $display("[TB] Pre-loading TCDM Memory for RUN 2...");
            $display("--------------------------------------------------");

            row_ptr_base_addr_i = 32'h0000_1000;
            b_base_addr_i       = 32'h0000_2000;
            a_base_addr_i       = 32'h0000_3000;
            col_id_base_addr_i  = 32'h0000_4000;
            c_base_addr_i       = 32'h0000_6000; // Nuovo indirizzo di output per la Run 2

            row_ptr_num_words_i = ROW_PTR_NUM_WORDS;
            b_num_words_i       = NUM_ROWS;

            // 1. Nuovi Row Pointers (L'ultimo elemento indica 20 NNZ totali)
            addr_offset = row_ptr_base_addr_i >> 4;
            tcdm_memory[addr_offset + 0] = {
                8'd20, 8'd18, 8'd16, 8'd14, 
                8'd12, 8'd11, 8'd10, 8'd9, 
                8'd8,  8'd7,  8'd6,  8'd5, 
                8'd4,  8'd3,  8'd2,  8'd0
            };
            tcdm_memory[addr_offset + 1] = {112'd0, 8'd20}; // Ultimo puntatore = 20 NNZ

            // 2. Nuova Matrice B
            addr_offset = b_base_addr_i >> 4;
            for (int r = 0; r < NUM_ROWS; r++) begin
                tcdm_memory[addr_offset + r] = {
                    8'($urandom() % 15 + 1), 8'($urandom() % 15 + 1), 8'($urandom() % 15 + 1), 8'($urandom() % 15 + 1),
                    8'($urandom() % 15 + 1), 8'($urandom() % 15 + 1), 8'($urandom() % 15 + 1), 8'($urandom() % 15 + 1),
                    8'($urandom() % 15 + 1), 8'($urandom() % 15 + 1), 8'($urandom() % 15 + 1), 8'($urandom() % 15 + 1),
                    8'($urandom() % 15 + 1), 8'($urandom() % 15 + 1), 8'($urandom() % 15 + 1), 8'($urandom() % 15 + 1)
                };
            end

             // --- STAMPA DELLA MATRICE B IN FORMATO DECIMALE ---
            $display("==================================================");
            $display("    GENERATED RANDOM MATRIX B2 (16x16, INT8)       ");
            $display("==================================================");
            for (int r = 0; r < NUM_ROWS; r++) begin
                logic [127:0] b_row_val;
                b_row_val = tcdm_memory[addr_offset + r];
                $write("Row %2d -> [", r);
                // Stampa i 16 elementi decimali separati da virgola
                for (int e = 15; e >= 0; e--) begin
                    $write("%3d", b_row_val[e*8 +: 8]);
                    if (e > 0) $write(", ");
                end
                $display("]");
            end
            $display("==================================================\n");

            // 3. Nuovi Elementi non-nulli di A (20 elementi)
            addr_offset = a_base_addr_i >> 4;
            tcdm_memory[addr_offset + 0] = {
                8'd9, 8'd8, 8'd7, 8'd6, 
                8'd5, 8'd4, 8'd3, 8'd2, 
                8'd1, 8'd9, 8'd8, 8'd7, 
                8'd6, 8'd5, 8'd4, 8'd3
            };
            tcdm_memory[addr_offset + 1] = {
                96'd0,
                8'd4, 8'd3, 8'd2, 8'd1
            };

            // 4. Nuovi Column IDs (20 ID)
            addr_offset = col_id_base_addr_i >> 4;
            tcdm_memory[addr_offset + 0] = {
                8'd15, 8'd14, 8'd13, 8'd12, 
                8'd11, 8'd10, 8'd9,  8'd8, 
                8'd7,  8'd6,  8'd5,  8'd4, 
                8'd3,  8'd2,  8'd1,  8'd0
            };
            tcdm_memory[addr_offset + 1] = {
                96'd0,
                8'd3,  8'd2,  8'd1,  8'd0
            };

            $display("[TB] RUN 2 Data Loaded Successfully.\n");
        end
    endtask

    // =========================================================================
    // Sequenza Principale di Test
    // =========================================================================
    initial begin
        clk_i   = 0;
        rst_ni  = 0;
        clear_i = 0;
        start_i = 0;

        a_base_addr_i       = 0;
        col_id_base_addr_i  = 0;
        row_ptr_base_addr_i = 0;
        b_base_addr_i       = 0;
        c_base_addr_i       = 0;
        row_ptr_num_words_i = 0;
        b_num_words_i       = 0;

        #20;
        rst_ni = 1;
        #10;

        // ---------------------------------------------------------------------
        // PRIMA ESECUZIONE (RUN 1)
        // ---------------------------------------------------------------------
        populate_tcdm_memory_run1();

        #20;
        start_i = 1'b1;
        #10;
        start_i = 1'b0;

        wait(done_o == 1'b1);
        #20;

        $display("==================================================");
        $display("   RUN 1: FINAL MATRIX C RESULTS FROM TCDM        ");
        $display("==================================================");
        for (int r = 0; r < NUM_ROWS; r++) begin
            int c_base_offset;
            logic [127:0] c_row_val;
            c_base_offset = c_base_addr_i >> 4;
            c_row_val     = tcdm_memory[c_base_offset + r];
            
            $write("Row %2d -> [", r);
            for (int e = 15; e >= 0; e--) begin
                $write("%4d ", c_row_val[e*8 +: 8]);
                if (e > 0) $write(", ");
            end
            $display("]");
        end
        $display("==================================================\n");

        // ---------------------------------------------------------------------
        // SECONDA ESECUZIONE (RUN 2 - Nuova Matrice con diverso numero di NNZ)
        // ---------------------------------------------------------------------
        #50;
        $display("[TB] Resetting/Clearing SCM Buffers for Second Run...");
        clear_i = 1'b1;
        #20;
        clear_i = 1'b0;
        #20;

        populate_tcdm_memory_run2();

        #20;
        start_i = 1'b1;
        #10;
        start_i = 1'b0;

        wait(done_o == 1'b1);
        #20;

        $display("==================================================");
        $display("   RUN 2: FINAL MATRIX C RESULTS FROM TCDM        ");
        $display("==================================================");
        for (int r = 0; r < NUM_ROWS; r++) begin
            int c_base_offset;
            logic [127:0] c_row_val;
            c_base_offset = c_base_addr_i >> 4;
            c_row_val     = tcdm_memory[c_base_offset + r];
            
            $write("Row %2d -> [", r);
            for (int e = 15; e >= 0; e--) begin
                $write("%4d ", c_row_val[e*8 +: 8]);
                if (e > 0) $write(", ");
            end
            $display("]");
        end
        $display("==================================================\n");

        #50;
        $finish;
    end

endmodule
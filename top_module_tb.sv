`timescale 1ns/1ps

module top_module_tb;

    // --- Module Parameters ---
    parameter int unsigned DATA_WIDTH      = 8;
    parameter int unsigned NUM_MACS        = 16;
    parameter int unsigned NUM_ROWS        = 16;
    parameter int unsigned TOTAL_NNZ       = 28;
    parameter int unsigned TOTAL_PTRS      = 17; // Allineato a 16 righe + 1
    parameter int unsigned STREAM_WORD_BIT = 128; // Aggiornato a 128-bit
    parameter int unsigned DATA_WIDTH_OUT  = 8;   // Aggiornato a 8-bit
    parameter bit          USE_LATCHES     = 0;

    localparam int unsigned ROW_PTR_ELEMS_PER_WORD = STREAM_WORD_BIT / DATA_WIDTH; // 128 / 8 = 16
    localparam int unsigned ROW_PTR_NUM_WORDS      = (TOTAL_PTRS + ROW_PTR_ELEMS_PER_WORD - 1) / ROW_PTR_ELEMS_PER_WORD; // 17 / 16 = 2
    localparam int unsigned B_NUM_WORDS_PER_ROW    = (NUM_MACS * DATA_WIDTH) / STREAM_WORD_BIT; // 1 (16 * 8 / 128)
    localparam int unsigned WORDS_PER_C_ROW        = (NUM_MACS * DATA_WIDTH_OUT) / STREAM_WORD_BIT; // 1 (16 * 8 / 128)

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

    logic [15:0] a_num_words_i;
    logic [15:0] col_id_num_words_i;
    logic [15:0] row_ptr_num_words_i;
    logic [15:0] b_num_words_i;

    // --- TCDM Interface Instantiation (DW = 128-bit) ---
    hci_core_intf #(.DW(128), .AW(32)) tcdm_if (.clk(clk_i));

    // --- Clock Generation (100 MHz) ---
    always #5 clk_i = ~clk_i;

    // --- Top Module Instantiation (Integrated with Streamer) ---
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
        .b_num_words_i       (b_num_words_i),
        .a_num_words_i       (a_num_words_i),
        .col_id_num_words_i  (col_id_num_words_i)
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
                    // Indirizzamento basato su parole da 16 byte (shift a destra di 4)
                    tcdm_if.r_data  <= tcdm_memory[tcdm_if.add[31:4]];
                    tcdm_if.r_valid <= 1'b1;
                end else begin
                    tcdm_memory[tcdm_if.add[31:4]] <= tcdm_if.data;
                end
            end
        end
    end

    // --- Task di Pre-caricamento della Memoria TCDM (128-bit pacchetti) ---
    task populate_tcdm_memory();
        int addr_offset;
        begin
            $display("[TB] Pre-loading TCDM Memory with 128-bit Input Data...");

            row_ptr_base_addr_i = 32'h0000_1000;
            b_base_addr_i       = 32'h0000_2000;
            a_base_addr_i       = 32'h0000_3000;
            col_id_base_addr_i  = 32'h0000_4000;
            c_base_addr_i       = 32'h0000_5000;

            row_ptr_num_words_i = ROW_PTR_NUM_WORDS; // 2 parole
            b_num_words_i       = NUM_ROWS;          // 1 parola per riga * 16 righe = 16 parole
            a_num_words_i       = 2;                 // 64 elementi NNZ / 16 per parola = 4 parole
            col_id_num_words_i  = 2;                 // 64 ID / 16 per parola = 4 parole

            // 1. Caricamento Row Pointers (17 puntatori in 2 parole da 128-bit)
            addr_offset = row_ptr_base_addr_i >> 4;
            tcdm_memory[addr_offset + 0] = {
                8'd26, 8'd24, 8'd23, 8'd20, 
                8'd18, 8'd18, 8'd16, 8'd15, 
                8'd12, 8'd11, 8'd10, 8'd6, 
                8'd3,  8'd2,  8'd2,  8'd0
            };
            tcdm_memory[addr_offset + 1] = {112'd0, 8'd28}; // Ultimo puntatore

            // 2. Caricamento Matrice B (16 righe, 1 parola da 128-bit ciascuna = 16 elementi INT8)
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
            $display("    GENERATED RANDOM MATRIX B (16x16, INT8)       ");
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

            // 3. Caricamento Non-Zero Values A (64 elementi in 4 parole da 128-bit)
            addr_offset = a_base_addr_i >> 4;
            tcdm_memory[addr_offset + 0] = {
                8'd6, 8'd4, 8'd3, 8'd2, 
                8'd2, 8'd8, 8'd1, 8'd5, 
                8'd10, 8'd11, 8'd10, 8'd6, 
                8'd1,  8'd2,  8'd3,  8'd4
            };
            tcdm_memory[addr_offset + 1] = {
                32'd0,
                8'd2, 8'd8, 8'd1, 8'd5,
                8'd7, 8'd9, 8'd3, 8'd2,
                8'd1, 8'd6, 8'd7, 8'd1
            };

            // 4. Caricamento Col IDs (64 ID in 4 parole da 128-bit)
            addr_offset = col_id_base_addr_i >> 4;
            tcdm_memory[addr_offset + 0] = {
                8'd6, 8'd14, 8'd3, 8'd2, 
                8'd2, 8'd8, 8'd11, 8'd15, 
                8'd10, 8'd11, 8'd10, 8'd6, 
                8'd1,  8'd2,  8'd3,  8'd4
            };
            tcdm_memory[addr_offset + 1] = {
                32'd0,
                8'd2, 8'd8, 8'd10, 8'd5,
                8'd7, 8'd9, 8'd3, 8'd2,
                8'd15, 8'd6, 8'd7, 8'd11
            };


            $display("[TB] TCDM Memory 128-bit pre-loaded successfully.\n");
        end
    endtask

    // --- Main Test Sequence ---
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
        a_num_words_i       = 0;
        col_id_num_words_i  = 0;
        row_ptr_num_words_i = 0;
        b_num_words_i       = 0;

        #20;
        rst_ni = 1;
        #10;

        // 1. Popolamento TCDM
        populate_tcdm_memory();

        // 2. Avvio Streamer
        #20;
        start_i = 1'b1;
        #10;
        start_i = 1'b0;

        // 3. Attesa completamento
        wait(done_o == 1'b1);
        #20;

        // 4. Stampa Risultati Matrice C (1 parola da 128-bit per riga contenente 16 elementi da 8-bit)
        $display("==================================================");
        $display("   FINAL MATRIX C RESULTS (8-bit) FROM TCDM       ");
        $display("==================================================");
        
        for (int r = 0; r < NUM_ROWS; r++) begin
            int c_base_offset;
            logic [127:0] c_row_val;
            c_base_offset = c_base_addr_i >> 4;
            c_row_val     = tcdm_memory[c_base_offset + r];
            
            $write("Row %2d -> [", r);
            // Stampa i 16 elementi INT8 separati
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
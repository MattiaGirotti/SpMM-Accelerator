`timescale 1ns/1ps

module top_module_tb;

    // --- Module Parameters ---
    parameter int unsigned DATA_WIDTH      = 8;
    parameter int unsigned NUM_MACS        = 16;
    parameter int unsigned NUM_ROWS        = 16;
    parameter int unsigned TOTAL_NNZ       = 64;
    parameter int unsigned TOTAL_PTRS      = 17; // Allineato a 16 righe + 1
    parameter int unsigned STREAM_WORD_BIT = 32;
    parameter int unsigned DATA_WIDTH_OUT  = 32;
    parameter bit          USE_LATCHES     = 0;

    localparam int unsigned ROW_PTR_ELEMS_PER_WORD = STREAM_WORD_BIT / DATA_WIDTH;
    localparam int unsigned ROW_PTR_NUM_WORDS      = (TOTAL_PTRS + ROW_PTR_ELEMS_PER_WORD - 1) / ROW_PTR_ELEMS_PER_WORD;
    localparam int unsigned B_NUM_WORDS_PER_ROW    = (NUM_MACS * DATA_WIDTH) / STREAM_WORD_BIT;
    localparam int unsigned WORDS_PER_C_ROW        = (NUM_MACS * DATA_WIDTH_OUT) / STREAM_WORD_BIT;

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

    // --- TCDM Interface Instantiation ---
    hci_core_intf #(.DW(32), .AW(32)) tcdm_if (.clk(clk_i));

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

    // --- Behavioral TCDM Memory Model ---
    logic [31:0] tcdm_memory [0:32767];

    initial begin
        for (int i = 0; i < 32767; i++) begin
            tcdm_memory[i] = 32'h0;
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
                    tcdm_if.r_data  <= tcdm_memory[tcdm_if.add[31:2]];
                    tcdm_if.r_valid <= 1'b1;
                end else begin
                    tcdm_memory[tcdm_if.add[31:2]] <= tcdm_if.data;
                end
            end
        end
    end

    // --- Task di Pre-caricamento della Memoria TCDM ---
    task populate_tcdm_memory();
        int addr_offset;
        begin
            $display("[TB] Pre-loading TCDM Memory with Input Matrices...");

            row_ptr_base_addr_i = 32'h0000_1000;
            b_base_addr_i       = 32'h0000_2000;
            a_base_addr_i       = 32'h0000_3000;
            col_id_base_addr_i  = 32'h0000_4000;
            c_base_addr_i       = 32'h0000_5000;

            row_ptr_num_words_i = ROW_PTR_NUM_WORDS;
            b_num_words_i       = NUM_ROWS * B_NUM_WORDS_PER_ROW;
            a_num_words_i       = 7;
            col_id_num_words_i  = 7;

            // 1. Caricamento Row Pointers (Indirizzo base: 0x1000)
            addr_offset = row_ptr_base_addr_i >> 2;
            tcdm_memory[addr_offset + 0] = {8'd6, 8'd2, 8'd2, 8'd0};
            tcdm_memory[addr_offset + 1] = {8'd12, 8'd11, 8'd10, 8'd8};
            tcdm_memory[addr_offset + 2] = {8'd18, 8'd18, 8'd16, 8'd15};
            tcdm_memory[addr_offset + 3] = {8'd26, 8'd24, 8'd23, 8'd20};
            tcdm_memory[addr_offset + 4] = {24'd0, 8'd28};

            // 2. Caricamento Matrice B con valori casuali tra 1 e 100 impaccati correttamente a 8-bit
            addr_offset = b_base_addr_i >> 2;
            for (int r = 0; r < NUM_ROWS; r++) begin
                for (int w = 0; w < B_NUM_WORDS_PER_ROW; w++) begin
                    tcdm_memory[addr_offset + (r * B_NUM_WORDS_PER_ROW) + w] = {
                        8'($urandom() % 100 + 1),
                        8'($urandom() % 100 + 1),
                        8'($urandom() % 100 + 1),
                        8'($urandom() % 100 + 1)
                    };
                end
            end

            // --- STAMPA DELLA MATRICE B IN FORMATO DECIMALE ---
            $display("==================================================");
            $display("    GENERATED RANDOM MATRIX B (Values 0 to 100)   ");
            $display("==================================================");
            for (int r = 0; r < NUM_ROWS; r++) begin
                $write("Row %2d -> [", r);
                for (int w = 0; w < B_NUM_WORDS_PER_ROW; w++) begin
                    logic [31:0] b_val;
                    b_val = tcdm_memory[addr_offset + (r * B_NUM_WORDS_PER_ROW) + w];
                    // Stampa i 4 singoli elementi INT8 decimali contenuti nella parola a 32-bit
                    $write("(%3d %3d %3d %3d) ", b_val[31:24], b_val[23:16], b_val[15:8], b_val[7:0]);
                    if (w < B_NUM_WORDS_PER_ROW - 1) $write("| ");
                end
                $display("]");
            end
            $display("==================================================\n");

            // 3. Caricamento Non-Zero Values A (Indirizzo base: 0x3000)
            addr_offset = a_base_addr_i >> 2;
            tcdm_memory[addr_offset + 0] = {8'd1, 8'd4, 8'd5, 8'd3};
            tcdm_memory[addr_offset + 1] = {8'd8, 8'd6, 8'd2, 8'd7};
            tcdm_memory[addr_offset + 2] = {8'd10, 8'd5, 8'd2, 8'd1};
            tcdm_memory[addr_offset + 3] = {8'd1, 8'd2, 8'd3, 8'd2};
            tcdm_memory[addr_offset + 4] = {8'd20, 8'd10, 8'd3, 8'd3};
            tcdm_memory[addr_offset + 5] = {8'd5, 8'd1, 8'd2, 8'd1};
            tcdm_memory[addr_offset + 6] = {8'd4, 8'd4, 8'd2, 8'd2};

            // 4. Caricamento Col IDs (Indirizzo base: 0x4000)
            addr_offset = col_id_base_addr_i >> 2;
            tcdm_memory[addr_offset + 0] = {8'd1, 8'd0, 8'd2, 8'd0};
            tcdm_memory[addr_offset + 1] = {8'd4, 8'd5, 8'd3, 8'd2};
            tcdm_memory[addr_offset + 2] = {8'd4, 8'd4, 8'd7, 8'd6};
            tcdm_memory[addr_offset + 3] = {8'd10, 8'd6, 8'd5, 8'd7};
            tcdm_memory[addr_offset + 4] = {8'd12, 8'd13, 8'd15, 8'd11};
            tcdm_memory[addr_offset + 5] = {8'd7, 8'd14, 8'd9, 8'd8};
            tcdm_memory[addr_offset + 6] = {8'd6, 8'd3, 8'd1, 8'd10};

            $display("[TB] TCDM Memory pre-loaded successfully.\n");
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

        // 4. Stampa Risultati Matrice C
        $display("==================================================");
        $display("       FINAL MATRIX C RESULTS FROM TCDM           ");
        $display("==================================================");
        
        for (int r = 0; r < NUM_ROWS; r++) begin
            int c_base_offset;
            c_base_offset = c_base_addr_i >> 2;
            $write("Row %2d -> [", r);
            for (int w = 0; w < WORDS_PER_C_ROW; w++) begin
                logic [31:0] val;
                val = tcdm_memory[c_base_offset + (r * WORDS_PER_C_ROW) + w];
                $write("%6d ", val);
                if (w < WORDS_PER_C_ROW - 1) $write("| ");
            end
            $display("]");
        end
        $display("==================================================\n");

        #50;
        $finish;
    end

endmodule
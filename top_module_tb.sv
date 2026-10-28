`timescale 1ns/1ps

module top_module_tb;

    // --- Module Parameters ---
    parameter int unsigned DATA_WIDTH      = 8;
    parameter int unsigned NUM_MACS        = 16;
    parameter int unsigned NUM_ROWS        = 16;
    parameter int unsigned TOTAL_NNZ       = 64;  
    parameter int unsigned TOTAL_PTRS      = 17;  
    parameter int unsigned STREAM_WORD_BIT = 128; 
    parameter int unsigned DATA_WIDTH_OUT  = 8;   
    parameter bit          USE_LATCHES     = 0;

    localparam int unsigned ROW_PTR_ELEMS_PER_WORD = STREAM_WORD_BIT / DATA_WIDTH; 
    localparam int unsigned ROW_PTR_NUM_WORDS      = (TOTAL_PTRS + ROW_PTR_ELEMS_PER_WORD - 1) / ROW_PTR_ELEMS_PER_WORD; 

    // --- Testbench Signals ---
    logic clk_i;
    logic rst_ni;
    logic clear_i;

    // --- Interfaces ---
    // 1. TCDM Master Interface per i dati (128-bit)
    hci_core_intf #(.DW(128), .AW(32)) tcdm_if (.clk(clk_i));

    // 2. HWPE Control Peripheral Interface per la configurazione (slave sul top module)
    hwpe_ctrl_intf_periph target_if (.clk(clk_i));

    // Segnale di fine calcolo (collegato indirettamente o monitorato)
    // Nota: possiamo monitorare lo status o attendere la fine tramite il bus
    logic done_o; // Se desideri esporlo o verificarlo dai registri

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
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .clear_i       (clear_i),
        .tcdm_master   (tcdm_if),
        .target        (target_if)   // <-- Connessione della porta di controllo
    );

    // --- Behavioral TCDM Memory Model (128-bit wide) ---
    logic [127:0] tcdm_memory [0:8191];

    initial begin
        for (int i = 0; i < 8191; i++) begin
            tcdm_memory[i] = 128'h0;
        end
    end

    // Gestione TCDM con Grant Combinazionale
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
    // TASK DI SCRITTURA DEI REGISTRI HWPE-CTRL (Emula il processore PULP)
    // =========================================================================
    task automatic write_register(input logic [31:0] addr, input logic [31:0] data);
        begin
            @(posedge clk_i);
            target_if.req   = 1'b1;
            target_if.wen   = 1'b0; // 0 = Scrittura (Write)
            target_if.add   = addr;
            target_if.data  = data;
            target_if.be    = 4'hF; // Byte enable attivo su tutti i 32 bit
            target_if.id    = '0;

            // Attende il grant dal decoder
            do begin
                @(posedge clk_i);
            end while (!target_if.gnt);

            target_if.req   = 1'b0;
            target_if.wen   = 1'b1;
            @(posedge clk_i);
        end
    endtask

    // =========================================================================
    // TASK DI LETTURA DEI REGISTRI (Opzionale, utile per controllare lo status)
    // =========================================================================
    task automatic read_register(input logic [31:0] addr, output logic [31:0] data);
        begin
            @(posedge clk_i);
            target_if.req   = 1'b1;
            target_if.wen   = 1'b1; // 1 = Lettura (Read)
            target_if.add   = addr;
            target_if.be    = 4'hF;
            target_if.id    = '0;

            do begin
                @(posedge clk_i);
            end while (!target_if.gnt);

            target_if.req   = 1'b0;
            
            // Attende la risposta valida r_valid
            do begin
                @(posedge clk_i);
            end while (!target_if.r_valid);

            data = target_if.r_data;
        end
    endtask

    // =========================================================================
    // TASK DI POPOLAMENTO MEMORIA (Invariato rispetto al precedente)
    // =========================================================================
    task populate_tcdm_memory_run1();
        int addr_offset;
        begin
            $display("[TB] Pre-loading TCDM Memory for RUN 1...");
            
            // 1. Caricamento Row Pointers (Indirizzo base 0x0000_1000)
            addr_offset = 32'h0000_1000 >> 4;
            tcdm_memory[addr_offset + 0] = {
                8'd26, 8'd24, 8'd23, 8'd20, 
                8'd18, 8'd18, 8'd16, 8'd15, 
                8'd12, 8'd11, 8'd10, 8'd6, 
                8'd3,  8'd2,  8'd2,  8'd0
            };
            tcdm_memory[addr_offset + 1] = {112'd0, 8'd26};

            // 2. Caricamento Matrice B (Indirizzo base 0x0000_2000)
            addr_offset = 32'h0000_2000 >> 4;
            for (int r = 0; r < NUM_ROWS; r++) begin
                tcdm_memory[addr_offset + r] = {
                    8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1,
                    8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1
                };
            end

            // 3. Caricamento A NNZ (Indirizzo base 0x0000_3000)
            addr_offset = 32'h0000_3000 >> 4;
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

            // 4. Caricamento Col IDs (Indirizzo base 0x0000_4000)
            addr_offset = 32'h0000_4000 >> 4;
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
        end
    endtask

    // =========================================================================
    // SEQUENZA PRINCIPALE DI TEST
    // =========================================================================
    initial begin
        clk_i         = 0;
        rst_ni        = 0;
        clear_i       = 0;
        target_if.req = 0;
        target_if.wen = 1;
        target_if.add = 0;
        target_if.data= 0;
        target_if.be  = 0;

        #20;
        rst_ni = 1;
        #10;

        // Popolamento dei dati in TCDM
        populate_tcdm_memory_run1();
        #20;

        // --- CONFIGURAZIONE TRAMITE I REGISTRI HWPE-CTRL (Offset da spmm_regif.rdl) ---
        $display("[TB] Configuring accelerator registers via control bus...");
        
        write_register(32'h0000_0020, 32'h0000_1000); // row_ptr_base_addr (@ 0x20)
        write_register(32'h0000_0024, 32'h0000_2000); // b_base_addr       (@ 0x24)
        write_register(32'h0000_0028, 32'h0000_3000); // a_base_addr       (@ 0x28)
        write_register(32'h0000_002c, 32'h0000_4000); // col_id_base_addr  (@ 0x2C)
        write_register(32'h0000_0030, 32'h0000_5000); // c_base_addr       (@ 0x30)
        write_register(32'h0000_0034, {16'd16, 16'd2}); // lengths: b_num_words=16, row_ptr_num_words=2 (@ 0x34)

        // --- AVVIO DEL JOB (COMMIT & TRIGGER) ---
        $display("[TB] Triggering job execution...");
        write_register(32'h0000_0000, 32'h0000_0000); // commit_trigger (@ 0x00) -> Scrive 0 per committare e partire

        // Attendiamo il completamento leggendo periodicamente lo status o monitorando i registri
        // In alternativa, possiamo fare un polling sul registro status o inserire un tempo di attesa stimato,
        // oppure leggere il registro running_job finché torna a 0.
        #5000; 

        $display("==================================================");
        $display("   FINAL MATRIX C RESULTS FROM TCDM (Run 1)       ");
        $display("==================================================");
        for (int r = 0; r < NUM_ROWS; r++) begin
            int c_base_offset;
            logic [127:0] c_row_val;
            c_base_offset = 32'h0000_5000 >> 4;
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
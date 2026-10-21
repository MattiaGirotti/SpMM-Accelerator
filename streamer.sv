// ============================================================================
// Module: streamer
// Description: HWPE/HCI Compliant Streamer for CSR SpMM Accelerator.
//              Generates TCDM read requests for A_nnz, ColID, RowPtr, B
//              and writes back matrix C results to TCDM memory.
// ============================================================================

import hci_package::*;
import hwpe_stream_package::*;

module streamer #(
    parameter int unsigned DATA_WIDTH      = 8,   // INT8
    parameter int unsigned NUM_MACS        = 16,  // Matrice 16x16
    parameter int unsigned NUM_ROWS        = 16,
    parameter int unsigned TOTAL_NNZ       = 64,
    parameter int unsigned TOTAL_PTRS      = 65,
    parameter int unsigned STREAM_WORD_BIT = 32,  // 32-bit TCDM / HWPE Stream
    parameter int unsigned DATA_WIDTH_OUT  = 32
)(
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,

    // --- Control & Configuration Interface ---
    input  logic        start_i,
    output logic        busy_o,
    output logic        done_o,

    // Base addresses in TCDM memory
    input  logic [31:0] a_base_addr_i,      // A NNZ values base address
    input  logic [31:0] col_id_base_addr_i, // ColID base address
    input  logic [31:0] row_ptr_base_addr_i,// RowPtr base address
    input  logic [31:0] b_base_addr_i,      // Dense matrix B base address
    input  logic [31:0] c_base_addr_i,      // Output matrix C base address

    // Total words to transfer per buffer
    input  logic [15:0] a_num_words_i,
    input  logic [15:0] col_id_num_words_i,
    input  logic [15:0] row_ptr_num_words_i,
    input  logic [15:0] b_num_words_i,

    // --- TCDM Master Interface (Initiator for memory read/write) ---
    hci_core_intf.initiator tcdm_master,

    // --- Direct Buffer Write Interfaces (To SpMM Top Module/Buffers) ---
    output logic                        a_write_en_o,
    output logic [STREAM_WORD_BIT-1:0]  a_wdata_o,

    output logic                        b_write_en_o,
    output logic [STREAM_WORD_BIT-1:0]  b_wdata_o,

    output logic                        col_id_write_en_o,
    output logic [STREAM_WORD_BIT-1:0]  col_id_wdata_o,

    output logic                        row_ptr_write_en_o,
    output logic [STREAM_WORD_BIT-1:0]  row_ptr_wdata_o,

    // --- Direct C Buffer Read Interface (From Output C Buffer) ---
    output logic [$clog2(NUM_ROWS)-1:0]                                      c_read_row_addr_o,
    output logic [$clog2((NUM_MACS*DATA_WIDTH_OUT)/STREAM_WORD_BIT)-1:0]     c_read_word_addr_o,
    input  logic [STREAM_WORD_BIT-1:0]                                       c_rdata_i,

    // Interface to Accelerator Core FSM
    output logic accel_start_o,
    input  logic accel_done_i
);

    localparam int unsigned WORDS_PER_C_ROW = (NUM_MACS * DATA_WIDTH_OUT) / STREAM_WORD_BIT; // 16 * 32 / 32 = 16

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_LD_ROW_PTR,
        ST_LD_B,
        ST_LD_A,
        ST_LD_COL_ID,
        ST_RUN_ACCEL,
        ST_ST_C_READ,
        ST_ST_C_WRITE,
        ST_DONE
    } streamer_state_e;

    streamer_state_e state_q, state_d;

    // Contatori separati per richieste inviate e risposte ricevute
    logic [15:0] req_cnt_q, req_cnt_d;
    logic [15:0] resp_cnt_q, resp_cnt_d;
    logic [31:0] current_addr_q, current_addr_d;

    // Matrix C Store Counters
    logic [$clog2(NUM_ROWS)-1:0]          c_row_cnt_q, c_row_cnt_d;
    logic [$clog2(WORDS_PER_C_ROW)-1:0]   c_word_cnt_q, c_word_cnt_d;

    // TCDM Control Assignments
    assign tcdm_master.be      = 4'b1111; // Full 32-bit word accesses
    assign tcdm_master.user    = '0;
    assign tcdm_master.id      = '0;
    assign tcdm_master.r_ready = 1'b1;
    assign tcdm_master.ereq    = 1'b0;
    assign tcdm_master.r_eready= 1'b1;

    // FSM State Register
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q        <= ST_IDLE;
            req_cnt_q      <= '0;
            resp_cnt_q     <= '0;
            current_addr_q <= '0;
            c_row_cnt_q    <= '0;
            c_word_cnt_q   <= '0;
        end else if (clear_i) begin
            state_q        <= ST_IDLE;
            req_cnt_q      <= '0;
            resp_cnt_q     <= '0;
            current_addr_q <= '0;
            c_row_cnt_q    <= '0;
            c_word_cnt_q   <= '0;
        end else begin
            state_q        <= state_d;
            req_cnt_q      <= req_cnt_d;
            resp_cnt_q     <= resp_cnt_d;
            current_addr_q <= current_addr_d;
            c_row_cnt_q    <= c_row_cnt_d;
            c_word_cnt_q   <= c_word_cnt_d;
        end
    end

    // Combinational Next State & Control Logic
    always_comb begin
        state_d         = state_q;
        req_cnt_d       = req_cnt_q;
        resp_cnt_d      = resp_cnt_q;
        current_addr_d  = current_addr_q;
        c_row_cnt_d     = c_row_cnt_q;
        c_word_cnt_d    = c_word_cnt_q;

        busy_o          = 1'b1;
        done_o          = 1'b0;
        accel_start_o   = 1'b0;

        // TCDM Defaults
        tcdm_master.req  = 1'b0;
        tcdm_master.add  = current_addr_q;
        tcdm_master.wen  = 1'b1; // Read by default (1 = Read, 0 = Write)
        tcdm_master.data = '0;

        // Buffer Writes Defaults
        a_write_en_o       = 1'b0;
        a_wdata_o          = tcdm_master.r_data;
        b_write_en_o       = 1'b0;
        b_wdata_o          = tcdm_master.r_data;
        col_id_write_en_o  = 1'b0;
        col_id_wdata_o     = tcdm_master.r_data;
        row_ptr_write_en_o = 1'b0;
        row_ptr_wdata_o    = tcdm_master.r_data;

        c_read_row_addr_o  = c_row_cnt_q;
        c_read_word_addr_o = c_word_cnt_q;

        case (state_q)

            ST_IDLE: begin
                busy_o = 1'b0;
                if (start_i) begin
                    req_cnt_d      = '0;
                    resp_cnt_d     = '0;
                    current_addr_d = row_ptr_base_addr_i;
                    state_d        = ST_LD_ROW_PTR;
                end
            end

            // --- 1. STREAM IN: ROW POINTERS ---
            ST_LD_ROW_PTR: begin
                if (req_cnt_q < row_ptr_num_words_i) begin
                    tcdm_master.req = 1'b1;
                    tcdm_master.wen = 1'b1;
                    if (tcdm_master.gnt) begin
                        req_cnt_d      = req_cnt_q + 1'b1;
                        current_addr_d = current_addr_q + 32'd4;
                    end
                end

                if (tcdm_master.r_valid) begin
                    row_ptr_write_en_o = 1'b1;
                    resp_cnt_d         = resp_cnt_q + 1'b1;
                end

                if (resp_cnt_q == row_ptr_num_words_i - 1 && tcdm_master.r_valid) begin
                    req_cnt_d      = '0;
                    resp_cnt_d     = '0;
                    current_addr_d = b_base_addr_i;
                    state_d        = ST_LD_B;
                end
            end

            // --- 2. STREAM IN: MATRIX B ---
            ST_LD_B: begin
                if (req_cnt_q < b_num_words_i) begin
                    tcdm_master.req = 1'b1;
                    tcdm_master.wen = 1'b1;
                    if (tcdm_master.gnt) begin
                        req_cnt_d      = req_cnt_q + 1'b1;
                        current_addr_d = current_addr_q + 32'd4;
                    end
                end

                if (tcdm_master.r_valid) begin
                    b_write_en_o = 1'b1;
                    resp_cnt_d   = resp_cnt_q + 1'b1;
                end

                if (resp_cnt_q == b_num_words_i - 1 && tcdm_master.r_valid) begin
                    req_cnt_d      = '0;
                    resp_cnt_d     = '0;
                    current_addr_d = a_base_addr_i;
                    state_d        = ST_LD_A;
                end
            end

            // --- 3. STREAM IN: MATRIX A NNZ ---
            ST_LD_A: begin
                if (req_cnt_q < a_num_words_i) begin
                    tcdm_master.req = 1'b1;
                    tcdm_master.wen = 1'b1;
                    if (tcdm_master.gnt) begin
                        req_cnt_d      = req_cnt_q + 1'b1;
                        current_addr_d = current_addr_q + 32'd4;
                    end
                end

                if (tcdm_master.r_valid) begin
                    a_write_en_o = 1'b1;
                    resp_cnt_d   = resp_cnt_q + 1'b1;
                end

                if (resp_cnt_q == a_num_words_i - 1 && tcdm_master.r_valid) begin
                    req_cnt_d      = '0;
                    resp_cnt_d     = '0;
                    current_addr_d = col_id_base_addr_i;
                    state_d        = ST_LD_COL_ID;
                end
            end

            // --- 4. STREAM IN: COL ID ---
            ST_LD_COL_ID: begin
                if (req_cnt_q < col_id_num_words_i) begin
                    tcdm_master.req = 1'b1;
                    tcdm_master.wen = 1'b1;
                    if (tcdm_master.gnt) begin
                        req_cnt_d      = req_cnt_q + 1'b1;
                        current_addr_d = current_addr_q + 32'd4;
                    end
                end

                if (tcdm_master.r_valid) begin
                    col_id_write_en_o = 1'b1;
                    resp_cnt_d        = resp_cnt_q + 1'b1;
                end

                if (resp_cnt_q == col_id_num_words_i - 1 && tcdm_master.r_valid) begin
                    req_cnt_d  = '0;
                    resp_cnt_d = '0;
                    state_d    = ST_RUN_ACCEL;
                end
            end

            // --- 5. EXECUTION: TRIGGER SPMM CORE ---
            ST_RUN_ACCEL: begin
                accel_start_o  = 1'b1;
                c_row_cnt_d    = '0;
                c_word_cnt_d   = '0;
                current_addr_d = c_base_addr_i;
                if (accel_done_i) begin
                    // Imposta i puntatori sul primo elemento del C-buffer prima di passare alla lettura
                    c_row_cnt_d    = '0;
                    c_word_cnt_d   = '0;
                    state_d        = ST_ST_C_READ;
                end
            end

            // --- 6. STREAM OUT: STORE C MATRIX TO TCDM ---
            ST_ST_C_READ: begin
                // Mantieni l'indirizzo impostato e attendi un ciclo di clock per stabilizzare c_rdata_i
                c_read_row_addr_o  = c_row_cnt_q;
                c_read_word_addr_o = c_word_cnt_q;
                state_d = ST_ST_C_WRITE;
            end

            ST_ST_C_WRITE: begin
                tcdm_master.req  = 1'b1;
                tcdm_master.wen  = 1'b0; // Scrittura in TCDM
                tcdm_master.data = c_rdata_i; // Dato prelevato dal C-buffer

                // Mantieni gli indirizzi di lettura stabili durante la richiesta TCDM in stallo
                c_read_row_addr_o  = c_row_cnt_q;
                c_read_word_addr_o = c_word_cnt_q;

                if (tcdm_master.gnt) begin
                    current_addr_d = current_addr_q + 32'd4;
                    
                    if (c_word_cnt_q == WORDS_PER_C_ROW - 1) begin
                        c_word_cnt_d = '0;
                        if (c_row_cnt_q == NUM_ROWS - 1) begin
                            state_d = ST_DONE;
                        end else begin
                            c_row_cnt_d = c_row_cnt_q + 1'b1;
                            state_d     = ST_ST_C_READ;
                        end
                    end else begin
                        c_word_cnt_d = c_word_cnt_q + 1'b1;
                        state_d      = ST_ST_C_READ;
                    end
                end
            end

            ST_DONE: begin
                done_o = 1'b1;
                busy_o = 1'b0;
                if (!start_i) begin
                    state_d = ST_IDLE;
                end
            end

            default: state_d = ST_IDLE;

        endcase
    end

endmodule
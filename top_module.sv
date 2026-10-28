// ============================================================================
// Module: top_module (Aggiornato con spmm_target_decoder)
// ============================================================================

import hci_package::*;
import hwpe_ctrl_package::*;
import spmm_pkg::*;     

module top_module #(
    parameter int unsigned DATA_WIDTH      = 8,           // INT8 data width
    parameter int unsigned NUM_MACS        = 16,          // Parallel MAC units
    parameter int unsigned NUM_ROWS        = 16,          // Number of rows
    parameter int unsigned TOTAL_NNZ       = 64,          // Max total non-zero elements
    parameter int unsigned TOTAL_PTRS      = 17,          // Total row pointers
    parameter int unsigned STREAM_WORD_BIT = 128,         // PULP Streamer word width
    parameter int unsigned DATA_WIDTH_OUT  = 8,           // Output precision
    parameter bit          USE_LATCHES     = 0            // 1: Clock Gating + Latches, 0: Flip-Flops
)(
    input  logic                                                clk_i,
    input  logic                                                rst_ni,
    input  logic                                                clear_i,

    // --- TCDM Master Interface (To Memory Subsystem) ---
    hci_core_intf.initiator                                     tcdm_master,

    // --- HWPE-Ctrl Target Port (Front-End Interface) ---
    hwpe_ctrl_intf_periph.slave                                 target
);

    // -------------------------------------------------------------------------
    // Segnali interni per il decoder e la configurazione
    // -------------------------------------------------------------------------
    spmm_config_t accel_config;
    logic         accel_config_valid;
    logic         target_clear;
    logic         done_o;
    logic         busy_o;
    logic         accel_start;
    logic         accel_done;

    // Connessione del Soft Clear globale (derivato sia dal pin esterno che dal target soft-clear)
    logic         global_clear;
    assign global_clear = clear_i | target_clear;

    // -------------------------------------------------------------------------
    // 0. Instanziazione del Decoder e Register File HWPE
    // -------------------------------------------------------------------------
    spmm_target_decoder #(
        .OpIdWidth ( 4 )
    ) i_spmm_target_decoder (
        .clk_i            ( clk_i              ),
        .rst_ni           ( rst_ni             ),
        .clear_i          ( clear_i            ),
        .target_clear_o   ( target_clear       ),
        .config_ready_i   ( ~busy_o            ),
        .op_done_i        ( done_o             ),
        .config_valid_o   ( accel_config_valid ),
        .config_o         ( accel_config       ),
        .target           ( target             )
    );

    // Streamer <-> Buffers Write Interconnect
    logic                                               a_write_en;
    logic [STREAM_WORD_BIT-1:0]                         a_wdata;
    logic                                               b_write_en;
    logic [STREAM_WORD_BIT-1:0]                         b_wdata;
    logic                                               col_id_write_en;
    logic [STREAM_WORD_BIT-1:0]                         col_id_wdata;
    logic                                               row_ptr_write_en;
    logic [STREAM_WORD_BIT-1:0]                         row_ptr_wdata;

    // Streamer <-> C Buffer Read Interconnect
    logic [$clog2(NUM_ROWS)-1:0]                        c_read_row_addr;
    logic [$clog2((NUM_MACS * DATA_WIDTH_OUT) / STREAM_WORD_BIT)-1:0]                 c_read_word_addr;
    logic [STREAM_WORD_BIT-1:0]                         c_rdata;

    // row_ptr_buffer <-> scheduler
    logic [$clog2(TOTAL_PTRS-1)-1:0]                    row_ptr_read_addr;
    logic [DATA_WIDTH-1:0]                              row_ptr_start;
    logic [DATA_WIDTH-1:0]                              row_ptr_end;

    // colID_buffer <-> scheduler
    logic [$clog2(TOTAL_NNZ)-1:0]                       col_id_read_addr;
    logic [DATA_WIDTH-1:0]                              col_id_data;

    // a_buffer <-> scheduler / datapath
    logic [$clog2(TOTAL_NNZ)-1:0]                       a_read_addr;
    logic unsigned [DATA_WIDTH-1:0]                       a_data;

    // b_buffer <-> scheduler / datapath
    logic [$clog2(NUM_ROWS)-1:0]                        b_read_row_addr;
    logic unsigned [NUM_MACS-1:0][DATA_WIDTH-1:0]         b_data;

    // c_buffer <-> scheduler / datapath
    logic                                               c_buf_write_en;
    logic [$clog2(NUM_ROWS)-1:0]                        c_buf_write_row_addr;

    // scheduler <-> datapath
    logic                                               dp_in_valid;
    logic                                               dp_in_ready;
    logic [DATA_WIDTH-1:0]                              dp_nnz_iterations;
    logic                                               dp_out_valid;
    logic                                               dp_out_ready;
    logic unsigned [NUM_MACS-1:0][DATA_WIDTH_OUT-1:0]    dp_data_out;
    logic                                               dp_matrix_end;

    // -------------------------------------------------------------------------
    // 1. Instantiation of SpMM Streamer (Configurato tramite `accel_config`)
    // -------------------------------------------------------------------------
    streamer #(
        .DATA_WIDTH      (DATA_WIDTH),
        .NUM_MACS        (NUM_MACS),
        .NUM_ROWS        (NUM_ROWS),
        .TOTAL_NNZ       (TOTAL_NNZ),
        .TOTAL_PTRS      (TOTAL_PTRS),
        .STREAM_WORD_BIT (STREAM_WORD_BIT),
        .DATA_WIDTH_OUT  (DATA_WIDTH_OUT)
    ) i_spmm_streamer (
        .clk_i                (clk_i),
        .rst_ni               (rst_ni),
        .clear_i              (global_clear),
        .start_i              (accel_config_valid),
        .busy_o               (busy_o),
        .done_o               (done_o),
        .a_base_addr_i        (accel_config.a_base_addr),
        .col_id_base_addr_i   (accel_config.col_id_base_addr),
        .row_ptr_base_addr_i  (accel_config.row_ptr_base_addr),
        .b_base_addr_i        (accel_config.b_base_addr),
        .c_base_addr_i        (accel_config.c_base_addr),
        .row_ptr_num_words_i  (accel_config.row_ptr_num_words),
        .b_num_words_i        (accel_config.b_num_words),
        .tcdm_master          (tcdm_master),
        .a_write_en_o         (a_write_en),
        .a_wdata_o            (a_wdata),
        .b_write_en_o         (b_write_en),
        .b_wdata_o            (b_wdata),
        .col_id_write_en_o    (col_id_write_en),
        .col_id_wdata_o       (col_id_wdata),
        .row_ptr_write_en_o   (row_ptr_write_en),
        .row_ptr_wdata_o      (row_ptr_wdata),
        .c_read_row_addr_o    (c_read_row_addr),
        .c_read_word_addr_o   (c_read_word_addr),
        .c_rdata_i            (c_rdata),
        .accel_start_o        (accel_start),
        .accel_done_i         (accel_done)
    );

    // -------------------------------------------------------------------------
    // 2. Instantiation of SCM Input Buffers
    // -------------------------------------------------------------------------
    a_buffer #(
        .DATA_WIDTH      (DATA_WIDTH),
        .TOTAL_NNZ       (TOTAL_NNZ),
        .STREAM_WORD_BIT (STREAM_WORD_BIT),       
        .USE_LATCHES     (USE_LATCHES)
    ) i_a_buffer (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (global_clear),
        .write_en_i        (a_write_en),
        .wdata_i           (a_wdata),
        .read_addr_i       (a_read_addr),
        .rdata_a_o         (a_data)
    );

    b_buffer #(
        .DATA_WIDTH      (DATA_WIDTH),
        .NUM_MACS        (NUM_MACS),
        .NUM_B_ROWS      (NUM_ROWS),
        .STREAM_WORD_BIT (STREAM_WORD_BIT),    
        .USE_LATCHES     (USE_LATCHES)
    ) i_b_buffer (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (global_clear),
        .write_en_i        (b_write_en),
        .wdata_i           (b_wdata),
        .read_row_addr_i   (b_read_row_addr),
        .rdata_b_o         (b_data)
    );

    colID_buffer #(
        .DATA_WIDTH      (DATA_WIDTH),
        .TOTAL_ID        (TOTAL_NNZ),
        .STREAM_WORD_BIT (STREAM_WORD_BIT),
        .USE_LATCHES     (USE_LATCHES)
    ) i_colID_buffer (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (global_clear),
        .write_en_i        (col_id_write_en),
        .wdata_i           (col_id_wdata),
        .read_addr_i       (col_id_read_addr),
        .rdata_o           (col_id_data)
    );

    row_ptr_buffer #(
        .DATA_WIDTH      (DATA_WIDTH),
        .TOTAL_PTRS      (TOTAL_PTRS),
        .STREAM_WORD_BIT (STREAM_WORD_BIT),
        .USE_LATCHES     (USE_LATCHES)
    ) i_row_ptr_buffer (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (global_clear),
        .write_en_i        (row_ptr_write_en),
        .wdata_i           (row_ptr_wdata),
        .read_row_idx_i    (row_ptr_read_addr),
        .rdata_start_o     (row_ptr_start),
        .rdata_end_o       (row_ptr_end)
    );

    // -------------------------------------------------------------------------
    // 3. Instantiation of SCM Output Buffer (C Buffer)
    // -------------------------------------------------------------------------
    c_buffer #(
        .DATA_WIDTH_OUT  (DATA_WIDTH_OUT),
        .NUM_MACS        (NUM_MACS),
        .NUM_C_ROWS      (NUM_ROWS),
        .STREAM_WORD_BIT (STREAM_WORD_BIT),
        .USE_LATCHES     (USE_LATCHES)
    ) i_c_buffer (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (global_clear),
        .write_en_i        (c_buf_write_en),
        .write_row_addr_i  (c_buf_write_row_addr),
        .wdata_i           (dp_data_out),
        .read_row_addr_i   (c_read_row_addr),
        .read_word_addr_i  (c_read_word_addr),
        .rdata_c_o         (c_rdata)
    );

    // -------------------------------------------------------------------------
    // 4. Instantiation of Scheduler FSM
    // -------------------------------------------------------------------------
    scheduler #(
        .DATA_WIDTH      (DATA_WIDTH),
        .NUM_MACS        (NUM_MACS),
        .NUM_ROWS        (NUM_ROWS),
        .TOTAL_NNZ       (TOTAL_NNZ),
        .TOTAL_PTRS      (TOTAL_PTRS),
        .DATA_WIDTH_OUT  (DATA_WIDTH_OUT)
    ) i_scheduler (
        .clk_i                 (clk_i),
        .rst_ni                (rst_ni),
        .clear_i               (global_clear),
        .start_i               (accel_start),
        .done_o                (accel_done),
        .row_ptr_read_addr_o   (row_ptr_read_addr),
        .row_ptr_start_i       (row_ptr_start),
        .row_ptr_end_i         (row_ptr_end),
        .col_id_read_addr_o    (col_id_read_addr),
        .col_id_i              (col_id_data),
        .a_read_addr_o         (a_read_addr),
        .b_read_row_addr_o     (b_read_row_addr),
        .c_write_en_o          (c_buf_write_en),
        .c_write_row_addr_o    (c_buf_write_row_addr),
        .dp_in_valid_o         (dp_in_valid),
        .dp_in_ready_i         (dp_in_ready),
        .dp_nnz_iterations_o   (dp_nnz_iterations),
        .dp_out_valid_i        (dp_out_valid),
        .dp_out_ready_o        (dp_out_ready),
        .dp_matrix_end_i       (dp_matrix_end)
    );

    // -------------------------------------------------------------------------
    // 5. Instantiation of Datapath
    // -------------------------------------------------------------------------
    datapath #(
        .DATA_WIDTH     (DATA_WIDTH),
        .NUM_MACS       (NUM_MACS),
        .NUM_ROWS       (NUM_ROWS),
        .DATA_WIDTH_OUT (DATA_WIDTH_OUT)
    ) i_datapath (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),
        .clear_i          (global_clear),
        .nnz_iterations_i (dp_nnz_iterations),
        .matrix_end_o     (dp_matrix_end),
        .in_valid_i       (dp_in_valid),
        .in_ready_o       (dp_in_ready),
        .data_a_i         (a_data),
        .data_b_i         (b_data),
        .out_valid_o      (dp_out_valid),
        .out_ready_i      (dp_out_ready),
        .data_out_o       (dp_data_out)
    );

endmodule
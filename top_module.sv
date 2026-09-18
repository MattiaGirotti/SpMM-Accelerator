// ============================================================================
// Module: top_module
// Description: Integrated CSR SpMM Accelerator.
//              SCM Buffers (A, B, ColID, RowPtr, C) connected directly 
//              to Datapath for data processing, controlled by Scheduler FSM.
// ============================================================================

module top_module #(
    parameter int unsigned DATA_WIDTH      = 8,           // INT8 data width
    parameter int unsigned NUM_MACS        = 4,           // Parallel MAC units (columns of B/C)
    parameter int unsigned NUM_ROWS        = 4,           // Number of rows in matrix B / output C
    parameter int unsigned TOTAL_NNZ       = 64,          // Max total storable non-zero elements
    parameter int unsigned TOTAL_PTRS      = 65,          // Total row pointers (NUM_ROWS + 1)
    parameter int unsigned STREAM_WORD_BIT = 32,          // PULP Streamer word width
    parameter int unsigned DATA_WIDTH_OUT  = 32,          // INT32 output precision
    parameter bit          REGISTERED_READ = 1,          // 1: 1-cycle latency SCM read
    parameter bit          USE_LATCHES     = 0           // 1: Clock Gating + Latches, 0: Flip-Flops
)(
    input  logic                                                clk_i,
    input  logic                                                rst_ni,
    input  logic                                                clear_i,

    // --- Control / Status Interface ---
    input  logic                                                start_i,
    output logic                                                busy_o,
    output logic                                                done_o,

    // --- External Write Interface from HWPE Streamer ---
    // a_buffer write port
    input  logic                                                a_write_en_i,
    input  logic [$clog2(TOTAL_NNZ/(STREAM_WORD_BIT/DATA_WIDTH))-1:0] a_write_word_addr_i,
    input  logic [STREAM_WORD_BIT-1:0]                          a_wdata_i,

    // b_buffer write port
    input  logic                                                b_write_en_i,
    input  logic [$clog2(NUM_ROWS)-1:0]                         b_write_row_addr_i,
    input  logic [$clog2((NUM_MACS*DATA_WIDTH)/STREAM_WORD_BIT)-1:0] b_write_word_addr_i,
    input  logic [STREAM_WORD_BIT-1:0]                          b_wdata_i,

    // colID_buffer write port
    input  logic                                                col_id_write_en_i,
    input  logic [$clog2(TOTAL_NNZ/(STREAM_WORD_BIT/DATA_WIDTH))-1:0] col_id_write_word_addr_i,
    input  logic [STREAM_WORD_BIT-1:0]                          col_id_wdata_i,

    // row_ptr_buffer write port
    input  logic                                                row_ptr_write_en_i,
    input  logic [$clog2(((TOTAL_PTRS + (STREAM_WORD_BIT/16) - 1)/(STREAM_WORD_BIT/16)))-1:0] row_ptr_write_word_addr_i,
    input  logic [STREAM_WORD_BIT-1:0]                          row_ptr_wdata_i,

    // --- Read Interface to HWPE Streamer for Output Matrix C ---
    input  logic [$clog2(NUM_ROWS)-1:0]                         c_read_row_addr_i,
    input  logic [$clog2((NUM_MACS*DATA_WIDTH_OUT)/STREAM_WORD_BIT)-1:0] c_read_word_addr_i,
    output logic [STREAM_WORD_BIT-1:0]                          c_rdata_o
);

    // -------------------------------------------------------------------------
    // Internal Interconnect Signals
    // -------------------------------------------------------------------------

    // row_ptr_buffer <-> scheduler
    logic [$clog2(TOTAL_PTRS-1)-1:0]                   row_ptr_read_addr;
    logic [15:0]                                        row_ptr_start;
    logic [15:0]                                        row_ptr_end;

    // colID_buffer <-> scheduler
    logic [$clog2(TOTAL_NNZ)-1:0]                      col_id_read_addr;
    logic [DATA_WIDTH-1:0]                              col_id_data;

    // a_buffer <-> scheduler (addr) / datapath (data)
    logic [$clog2(TOTAL_NNZ)-1:0]                      a_read_addr;
    logic unsigned [DATA_WIDTH-1:0]                       a_data;

    // b_buffer <-> scheduler (addr) / datapath (data)
    logic [$clog2(NUM_ROWS)-1:0]                        b_read_row_addr;
    logic unsigned [NUM_MACS-1:0][DATA_WIDTH-1:0]         b_data;

    // c_buffer <-> scheduler (ctrl) / datapath (data)
    logic                                               c_buf_write_en;
    logic [$clog2(NUM_ROWS)-1:0]                        c_buf_write_row_addr;

    // scheduler <-> datapath (Handshake & Control Channel)
    logic                                               dp_in_valid;
    logic                                               dp_in_ready;
    logic [15:0]                                        dp_nnz_iterations;
    logic                                               dp_out_valid;
    logic                                               dp_out_ready;
    logic unsigned [NUM_MACS-1:0][DATA_WIDTH_OUT-1:0]    dp_data_out;
    logic                                               dp_matrix_end;

    // -------------------------------------------------------------------------
    // SCM Input Buffer Instantiations
    // -------------------------------------------------------------------------

    a_buffer #(
        .DATA_WIDTH      (DATA_WIDTH),
        .TOTAL_NNZ       (TOTAL_NNZ),
        .STREAM_WORD_BIT (STREAM_WORD_BIT),
        .REGISTERED_READ (REGISTERED_READ),
        .USE_LATCHES     (USE_LATCHES)
    ) i_a_buffer (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (clear_i),
        .write_en_i        (a_write_en_i),
        .write_word_addr_i (a_write_word_addr_i),
        .wdata_i           (a_wdata_i),
        .read_addr_i       (a_read_addr),
        .rdata_a_o         (a_data)
    );

    b_buffer #(
        .DATA_WIDTH      (DATA_WIDTH),
        .NUM_MACS        (NUM_MACS),
        .NUM_B_ROWS      (NUM_ROWS),
        .STREAM_WORD_BIT (STREAM_WORD_BIT),
        .REGISTERED_READ (REGISTERED_READ),
        .USE_LATCHES     (USE_LATCHES)
    ) i_b_buffer (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (clear_i),
        .write_en_i        (b_write_en_i),
        .write_row_addr_i  (b_write_row_addr_i),
        .write_word_addr_i (b_write_word_addr_i),
        .wdata_i           (b_wdata_i),
        .read_row_addr_i   (b_read_row_addr),
        .rdata_b_o         (b_data)
    );

    colID_buffer #(
        .DATA_WIDTH      (DATA_WIDTH),
        .TOTAL_ID        (TOTAL_NNZ),
        .STREAM_WORD_BIT (STREAM_WORD_BIT),
        .REGISTERED_READ (REGISTERED_READ),
        .USE_LATCHES     (USE_LATCHES)
    ) i_colID_buffer (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (clear_i),
        .write_en_i        (col_id_write_en_i),
        .write_word_addr_i (col_id_write_word_addr_i),
        .wdata_i           (col_id_wdata_i),
        .read_addr_i       (col_id_read_addr),
        .rdata_o           (col_id_data)
    );

    row_ptr_buffer #(
        .DATA_WIDTH      (16),
        .TOTAL_PTRS      (TOTAL_PTRS),
        .STREAM_WORD_BIT (STREAM_WORD_BIT),
        .REGISTERED_READ (REGISTERED_READ),
        .USE_LATCHES     (USE_LATCHES)
    ) i_row_ptr_buffer (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (clear_i),
        .write_en_i        (row_ptr_write_en_i),
        .write_word_addr_i (row_ptr_write_word_addr_i),
        .wdata_i           (row_ptr_wdata_i),
        .read_row_idx_i    (row_ptr_read_addr),
        .rdata_start_o     (row_ptr_start),
        .rdata_end_o       (row_ptr_end)
    );

    // -------------------------------------------------------------------------
    // SCM Output Buffer Instantiation (C Buffer)
    // -------------------------------------------------------------------------

    c_buffer #(
        .DATA_WIDTH_OUT  (DATA_WIDTH_OUT),
        .NUM_MACS        (NUM_MACS),
        .NUM_C_ROWS      (NUM_ROWS),
        .STREAM_WORD_BIT (STREAM_WORD_BIT),
        .REGISTERED_READ (REGISTERED_READ),
        .USE_LATCHES     (USE_LATCHES)
    ) i_c_buffer (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .clear_i           (clear_i),
        
        // Write Port: Controlled by Scheduler + Data directly from Datapath
        .write_en_i        (c_buf_write_en),
        .write_row_addr_i  (c_buf_write_row_addr),
        .wdata_i           (dp_data_out),

        // Read Port: Exposed to top-level Streamer
        .read_row_addr_i   (c_read_row_addr_i),
        .read_word_addr_i  (c_read_word_addr_i),
        .rdata_c_o         (c_rdata_o)
    );

    // -------------------------------------------------------------------------
    // Scheduler Instantiation (Pure Control & Addressing FSM)
    // -------------------------------------------------------------------------

    scheduler #(
        .DATA_WIDTH     (DATA_WIDTH),
        .NUM_MACS       (NUM_MACS),
        .NUM_ROWS       (NUM_ROWS),
        .TOTAL_NNZ      (TOTAL_NNZ),
        .TOTAL_PTRS     (TOTAL_PTRS),
        .DATA_WIDTH_OUT (DATA_WIDTH_OUT),
        .REGISTERED_READ (REGISTERED_READ)
    ) i_scheduler (
        .clk_i                 (clk_i),
        .rst_ni                (rst_ni),
        .clear_i               (clear_i),
        .start_i               (start_i),
        .busy_o                (busy_o),
        .done_o                (done_o),
        
        // Memory Addressing Control
        .row_ptr_read_addr_o   (row_ptr_read_addr),
        .row_ptr_start_i       (row_ptr_start),
        .row_ptr_end_i         (row_ptr_end),

        .col_id_read_addr_o    (col_id_read_addr),
        .col_id_i              (col_id_data),

        .a_read_addr_o         (a_read_addr),
        
        .b_read_row_addr_o     (b_read_row_addr),
        
        .c_write_en_o          (c_buf_write_en),
        .c_write_row_addr_o    (c_buf_write_row_addr),

        // Datapath Handshake Control
        .dp_in_valid_o         (dp_in_valid),
        .dp_in_ready_i         (dp_in_ready),
        .dp_nnz_iterations_o   (dp_nnz_iterations),

        .dp_out_valid_i        (dp_out_valid),
        .dp_out_ready_o        (dp_out_ready),
        .dp_matrix_end_i       (dp_matrix_end)
    );

    // -------------------------------------------------------------------------
    // Datapath Instantiation (Direct Processing Datapath)
    // -------------------------------------------------------------------------

    datapath #(
        .DATA_WIDTH     (DATA_WIDTH),
        .NUM_MACS       (NUM_MACS),
        .NUM_ROWS       (NUM_ROWS),
        .DATA_WIDTH_OUT (DATA_WIDTH_OUT)
    ) i_datapath (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),
        .clear_i          (clear_i),
        .nnz_iterations_i (dp_nnz_iterations),
        .matrix_end_o     (dp_matrix_end),

        // Input Channel: Handshake from Scheduler, Data directly from A & B Buffers
        .in_valid_i       (dp_in_valid),
        .in_ready_o       (dp_in_ready),
        .data_a_i         (a_data),
        .data_b_i         (b_data),

        // Output Channel: Handshake from Scheduler, Data directly to C Buffer
        .out_valid_o      (dp_out_valid),
        .out_ready_i      (dp_out_ready),
        .data_out_o       (dp_data_out)
    );

endmodule
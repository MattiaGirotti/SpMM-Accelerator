`include "hci_helpers.svh"

module spmm_top
  import spmm_pkg::*;
  import hci_package::*;
  import hwpe_ctrl_package::*;
  import hwpe_stream_package::*;
#(
  parameter int unsigned  DataW                   = MaxDataW, // TCDM port dimension (in bits)
  parameter int unsigned  MisalignedAccessSupport = MisalignedAccessSupportDefault, // set to 1 to support misaligned accesses on TCDM
  parameter bit           EnableReordering        = 1'b0, // set to 1 to enable ROB-based reordering of outstanding TCDM transactions
  parameter int unsigned  Height                  = MaxDim, // Number of PEs within a row
  parameter int unsigned  Width                   = MaxDim, // Number of parallel rows
  parameter int unsigned  NumPipeRegs             = MaxPipeRegs-1, // Number of pipeline registers within each PE
  parameter int unsigned  EccChunkSize            = 32,
  parameter bit           LatchBuffers            = 0,
  parameter hci_size_parameter_t `HCI_SIZE_PARAM(tcdm) = '0
)(
  input  logic                    clk_i      ,
  input  logic                    rst_ni     ,
  input  logic                    test_mode_i,
  output logic                    busy_o     ,
  output logic                    evt_o      ,
  // TCDM master ports for the memory side
  hci_core_intf.initiator tcdm,
  // HWPE-ctrl target port (unused if CtrlIntfConfig = XIF)
  hwpe_ctrl_intf_periph.slave target
);

logic                       clk_acc;
logic                       clear;
logic                       target_clear; //esce da redmule_target_decoder
cntrl_streamer_t            cntrl_streamer; //lavorare su questo segnale
flags_streamer_t            flgs_streamer; //lavorare su questo segnale
logic                      scheduler_done, scheduler_start;
cntrl_scheduler_t           cntrl_scheduler;
cntrl_flags_t  cntrl_flags;
logic config_fifo_empty; //fifo config globale
a_buffer_ctrl_t a_buffer_ctrl;

tc_clk_gating i_acc_clock_gating (
  .clk_i     ( clk_i                                                   ),
  .en_i      ( dec_config_valid | ~config_fifo_empty | busy_o | busy_q ), //lavorare su questi segnali
  .test_en_i ( '0                                                      ),
  .clk_o     ( clk_acc                                                 )
);

// A streaming interface + A FIFO interface
hwpe_stream_intf_stream #( .DATA_WIDTH ( DataW ) ) a_stream_str       ( .clk( clk_acc ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DataW ) ) a_buffer_fifo      ( .clk( clk_acc ) );


hwpe_stream_intf_stream #( .DATA_WIDTH ( DataW ) ) b_stream_str       ( .clk( clk_acc ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DataW ) ) b_buffer_fifo      ( .clk( clk_acc ) );

hwpe_stream_intf_stream #( .DATA_WIDTH ( DataW ) ) colID_stream_str   ( .clk( clk_acc ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DataW ) ) colID_buffer_fifo  ( .clk( clk_acc ) );

hwpe_stream_intf_stream #( .DATA_WIDTH ( DataW ) ) rowPtr_stream_str( .clk( clk_acc ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DataW ) ) rowPtr_buffer_fifo( .clk( clk_acc ) );

hwpe_stream_intf_stream #( .DATA_WIDTH ( DataW ) ) c_buffer_q       ( .clk( clk_acc ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DataW ) ) c_buffer_fifo      ( .clk( clk_acc ) );

// The streamer will present a single master TCDM port used to stream data to and from the memeory.
spmm_streamer #(
  .DataW                   ( DataW                   ),
  .MisalignedAccessSupport ( MisalignedAccessSupport ),
  .EnableReordering        ( EnableReordering       ),
  .Height                  ( Height                  ),
  .NumPipeRegs             ( NumPipeRegs             ),
  .EccChunkSize            ( EccChunkSize            ),
  .`HCI_SIZE_PARAM(tcdm) ( `HCI_SIZE_PARAM(tcdm) )
) i_streamer      (
  .clk_i           ( clk_acc         ), //circa
  .rst_ni          ( rst_ni          ), //ok
  .test_mode_i     ( test_mode_i     ), //ok
  // Controller generated signals
  .enable_i        ( 1'b1            ), 
  .clear_i         ( target_clear    ), //decoder
  // Source interfaces for the incoming streams
  .a_stream_o      ( a_stream_str    ), //ok 
  .b_stream_o      ( b_stream_str    ), //ok
  .colID_stream_o  ( colID_stream_str ), //ok
  .rowPtr_stream_o ( rowPtr_stream_str ), //ok
  // Sink interface for the outgoing stream
  .c_stream_i      ( c_buffer_fifo   ), //ok
  // Master TCDM interface ports for the memory side
  .tcdm            ( tcdm            ), //ok 
  .ctrl_i          ( cntrl_streamer  ), //ok
  .flags_o         ( flgs_streamer   ) //ok
);

spmm_config_t a_sel_config, b_sel_config, spmm_config;
logic a_done;

spmm_config_fifo #(
  .FALL_THROUGH (0),
  .DEPTH (2),
  .dtype (spmm_config_t)
) i_a_config_fifo (
  .clk_i      ( clk_acc                                  ),
  .rst_ni     ( rst_ni                                   ),
  .flush_i    ( clear                                    ),
  .testmode_i ( '0                                       ),
  .full_o     (                                          ),
  .empty_o    (                                          ),
  .usage_o    (                                          ),
  .data_i     ( spmm_config                              ),
  .push_i     ( ~config_fifo_empty                             ),
  .data_o     ( a_sel_config                             ), //vedere se serve
  .pop_i      ( a_done                                   )
);

spmm_config_fifo #(
  .FALL_THROUGH (0),
  .DEPTH (2),
  .dtype (spmm_config_t)
) i_b_config_fifo (
  .clk_i      ( clk_acc                                  ),
  .rst_ni     ( rst_ni                                   ),
  .flush_i    ( clear                                    ),
  .testmode_i ( '0                                       ),
  .full_o     (                                          ),
  .empty_o    (                                          ),
  .usage_o    (                                          ),
  .data_i     ( spmm_config                              ),
  .push_i     ( ~config_fifo_empty                       ),
  .data_o     ( b_sel_config                             ), //vedere se serve
  .pop_i      ( flgs_streamer.b_stream_source_flags.done )
);

hwpe_stream_fifo #(
  .DATA_WIDTH     ( DataW         ),
  .FIFO_DEPTH     ( 4             )
) i_a_buffer_fifo (
  .clk_i          ( clk_acc       ),
  .rst_ni         ( rst_ni        ),
  .clear_i        ( clear         ),
  .flags_o        (               ),
  .push_i         ( a_stream_str  ),
  .pop_o          ( a_buffer_fifo )
);

hwpe_stream_fifo #(
  .DATA_WIDTH     ( DataW         ),
  .FIFO_DEPTH     ( 4             )
) i_colid_buffer_fifo (
  .clk_i          ( clk_acc       ),
  .rst_ni         ( rst_ni        ),
  .clear_i        ( clear         ),
  .flags_o        (               ),
  .push_i         ( colID_stream_str ),
  .pop_o          ( colID_buffer_fifo )
);

hwpe_stream_fifo #(
  .DATA_WIDTH     ( DataW         ),
  .FIFO_DEPTH     ( 4             )
) i_rowptr_buffer_fifo (
  .clk_i          ( clk_acc       ),
  .rst_ni         ( rst_ni        ),
  .clear_i        ( clear         ),
  .flags_o        (               ),
  .push_i         ( rowPtr_stream_str ),
  .pop_o          ( rowPtr_buffer_fifo )
);

hwpe_stream_fifo #(
  .DATA_WIDTH     ( DataW         ),
  .FIFO_DEPTH     ( 4             )
) i_b_buffer_fifo (
  .clk_i          ( clk_acc       ),
  .rst_ni         ( rst_ni        ),
  .clear_i        ( clear         ),
  .flags_o        (               ),
  .push_i         ( b_stream_str    ),
  .pop_o          ( b_buffer_fifo )
);

hwpe_stream_fifo #(
  .DATA_WIDTH     ( DataW         ),
  .FIFO_DEPTH     ( 4             )
) i_c_buffer_fifo (
  .clk_i          ( clk_acc       ),
  .rst_ni         ( rst_ni        ),
  .clear_i        ( clear         ),
  .flags_o        ( c_fifo_flgs   ), 
  .push_i         ( c_buffer_q    ),
  .pop_o          ( c_buffer_fifo   )
);

// Valid/Ready assignment DA LAVORARCI CON SCHEDULER
assign a_buffer_fifo.ready     = a_buffer_ctrl.load;
assign b_buffer_fifo.ready     = b_buffer_ctrl.load;

assign y_buffer_fifo.ready     = z_buffer_flgs.y_ready;

assign z_buffer_q.valid        = z_buffer_flgs.z_valid;

/*----------------------------------------------------------------*/
/* |                          Buffers                           | */
/*----------------------------------------------------------------*/

logic [DATA_WIDTH-1:0] a_data;
logic [NUM_MACS-1:0][DATA_WIDTH-1:0] b_data;
logic [DATA_WIDTH-1:0] colID_data;
logic [DATA_WIDTH-1:0] rowPtr_start;
logic [DATA_WIDTH-1:0] rowPtr_end;
logic [NUM_MACS-1:0][DATA_WIDTH_OUT-1:0] dp_data_out;

// -------------------------------------------------------------------------
// Internal Interconnect Signals
// -------------------------------------------------------------------------

// row_ptr_buffer <-> scheduler
logic [$clog2(TOTAL_PTRS-1)-1:0]                   row_ptr_read_addr;
logic [DATA_WIDTH-1:0]                             row_ptr_start;
logic [DATA_WIDTH-1:0]                             row_ptr_end;

// colID_buffer <-> scheduler
logic [$clog2(TOTAL_NNZ)-1:0]                      col_id_read_addr;
logic [DATA_WIDTH-1:0]                             col_id_data;

// a_buffer <-> scheduler (addr) / datapath (data)
logic [$clog2(TOTAL_NNZ)-1:0]                      a_read_addr;
logic unsigned [DATA_WIDTH-1:0]                    a_data;

// b_buffer <-> scheduler (addr) / datapath (data)
logic [$clog2(NUM_ROWS)-1:0]                        b_read_row_addr;
logic unsigned [NUM_MACS-1:0][DATA_WIDTH-1:0]       b_data;

// c_buffer <-> scheduler (ctrl) / datapath (data)
logic                                               c_buf_write_en;
logic [$clog2(NUM_ROWS)-1:0]                        c_buf_write_row_addr;

a_buffer #(
  .DATA_WIDTH(DATA_WIDTH),
  .TOTAL_NNZ(TOTAL_NNZ),
  .STREAM_WORD_BIT(DataW),
  .USE_LATCHES(LatchBuffers)
) i_a_buffer  (
  .clk_i             ( clk_acc            ),
  .rst_ni            ( rst_ni             ),
  .clear_i           ( clear              ),
  .write_en_i        ( a_buffer_fifo.ready ),       
  .wdata_i           ( a_buffer_fifo.data ),
  .read_addr_i       ( a_read_addr        ),
  .rdata_a_o         ( a_data             )
);

b_buffer #(
        .DATA_WIDTH      (DATA_WIDTH),
        .NUM_MACS        (NUM_MACS),
        .NUM_B_ROWS      (NUM_ROWS),
        .STREAM_WORD_BIT (DataW),    
        .USE_LATCHES     (LatchBuffers)
    ) i_b_buffer (
        .clk_i             ( clk_acc ),
        .rst_ni            ( rst_ni ),
        .clear_i           ( clear ),
        .ctrl_i            ( b_buffer_ctrl ),
        .flags_o           ( b_buffer_flgs ),
        .wdata_i           ( b_buffer_fifo.data ),
        .rdata_b_o         ( b_data )
    );

 colID_buffer #(
        .DATA_WIDTH      (DATA_WIDTH),
        .TOTAL_ID        (TOTAL_NNZ),
        .STREAM_WORD_BIT (DataW),
        .USE_LATCHES     (LatchBuffers)
    ) i_colID_buffer (
        .clk_i             ( clk_acc ),
        .rst_ni            ( rst_ni ),
        .clear_i           ( clear) ,
        .ctrl_i            ( colID_buffer_ctrl ),
        .flags_o           ( colID_buffer_flgs ),
        .wdata_i           ( colID_buffer_fifo.data ),
        .rdata_o           ( colID_data )
    );

    row_ptr_buffer #(
        .DATA_WIDTH      (DATA_WIDTH),
        .TOTAL_PTRS      (TOTAL_PTRS),
        .STREAM_WORD_BIT (DataW),
        .USE_LATCHES     (LatchBuffers)
    ) i_row_ptr_buffer (
        .clk_i             ( clk_acc ),
        .rst_ni            ( rst_ni ),
        .clear_i           ( clear ),
        .ctrl_i            ( rowPtr_buffer_ctrl ),
        .flags_o           ( rowPtr_buffer_flgs ),
        .wdata_i           ( rowPtr_buffer_fifo.data ),
        .rdata_start_o     ( rowPtr_start ),
        .rdata_end_o       ( rowPtr_end )
    );

    // -------------------------------------------------------------------------
    // SCM Output Buffer Instantiation (C Buffer)
    // -------------------------------------------------------------------------

    c_buffer #(
        .DATA_WIDTH_OUT  (DATA_WIDTH_OUT),
        .NUM_MACS        (NUM_MACS),
        .NUM_C_ROWS      (NUM_ROWS),
        .STREAM_WORD_BIT (DataW),
        .USE_LATCHES     (LatchBuffers)
    ) i_c_buffer (
        .clk_i             ( clk_acc ),
        .rst_ni            ( rst_ni ),
        .clear_i           ( clear ),
        .ctrl_i            ( c_buffer_ctrl ),
        .flags_o           ( c_buffer_flgs ),
        .wdata_i           ( dp_data_out ),
        .rdata_c_o         ( c_buffer_q.data )
    );

datapath #(
    .DATA_WIDTH     (DATA_WIDTH),
    .NUM_MACS       (NUM_MACS),
    .NUM_ROWS       (NUM_ROWS),
    .DATA_WIDTH_OUT (DATA_WIDTH_OUT)
) i_datapath (
    .clk_i            ( clk_acc ),
    .rst_ni           ( rst_ni ),
    .clear_i          ( target_clear ),
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

/*---------------------------------------------------------------*/
/* |                    Memory Controller                      | */
/*---------------------------------------------------------------*/

logic c_priority;
assign c_priority = c_buffer_flgs.z_priority & !c_fifo_flgs.empty; //lavorare su questo segnale

spmm_memory_scheduler #(
  .DW ( DataW  ),
) i_memory_scheduler (
  .clk_i             ( clk_acc         ), //ok
  .rst_ni            ( rst_ni          ), //ok
  .clear_i           ( target_clear    ), //ok
  .c_priority_i      ( c_priority      ), 
  .config_i          ( spmm_config     ), //ok
  .config_valid_i    ( ~config_fifo_empty    ), //ok
  .flgs_streamer_i   ( flgs_streamer   ), //ok
  .cntrl_scheduler_i ( cntrl_scheduler ), //ok
  .cntrl_flags_i     ( cntrl_flags     ), //ok
  .c_fifo_empty_o    ( c_fifo_empty    ), //ok
  .a_done_o          ( a_done          ), //ok
  .cntrl_streamer_o  ( cntrl_streamer  ) //ok
);

spmm_ctrl #(
  parameter int unsigned DataW            = 32,
  parameter bit          EnableReordering = 1'b0
) i_ctrl (
  .clk_i             ( clk_acc              ), //ok
  .rst_ni            ( rst_ni               ), //ok
  .test_mode_i       ( test_mode_i          ), //ok
  .busy_o            ( busy_o               ),  //ok
  .target_clear_i    ( target_clear         ), //ok
  .clear_o           ( clear                ), //ok
  .evt_o             ( evt_o                ), //decoder
  .config_i          ( dec_config_q         ), //decoder 
  .config_o          ( spmm_config          ), //ok
  .start_cfg_i       ( ~config_fifo_empty   ), //decoder
  .fifo_empty_i      ( c_fifo_empty         ), //ok
  .flgs_streamer_i   ( flgs_streamer        ), //ok
  // Status inputs from schedulers
  .scheduler_done_i  ( scheduler_done    ), //ok
  // Control outputs
  .scheduler_start_o ( scheduler_start   ), //ok
  .cntrl_scheduler_o ( cntrl_scheduler   ), //ok
  .cntrl_flags_o     ( cntrl_flags       )  //ok
);

scheduler #(
    .DATA_WIDTH      (DATA_WIDTH),
    .NUM_MACS        (NUM_MACS),
    .NUM_ROWS        (NUM_ROWS),
    .TOTAL_NNZ       (TOTAL_NNZ),
    .TOTAL_PTRS      (TOTAL_PTRS),
    .DATA_WIDTH_OUT  (DATA_WIDTH_OUT)
) i_scheduler (
    .clk_i                 (clk_acc), //ok
    .rst_ni                (rst_ni), //ok
    .clear_i               (target_clear), //ok
    .start_i               (scheduler_start), //ok
    .done_o                (scheduler_done), //ok
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

endmodule : spmm_top
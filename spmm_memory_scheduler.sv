module spmm_memory_scheduler
  import spmm_pkg::*;
  import hwpe_ctrl_package::*;
#(
  parameter int unsigned   DW   = MaxDataW,
  parameter int unsigned   ELW  = 8,   // INT8 per SpMM
  localparam int unsigned  D    = DW/ELW
) (
  input  logic                   clk_i            ,
  input  logic                   rst_ni           ,
  input  logic                   clear_i          ,
  input  logic                   c_priority_i     ,
  input  spmm_config_t           config_i         , // cntrl configuration input
  input  logic                   config_valid_i   , // cntrl valid
  input  flgs_streamer_t         flgs_streamer_i  , // cntrl flags from streamer
  input  cntrl_scheduler_t       cntrl_scheduler_i, // cntrl scheduler
  input  cntrl_flags_t           cntrl_flags_i    , // cntrl flags
  output logic                   c_fifo_empty_o   , // status output for C sink FIFO
  //output logic                   c_fifo_full_o    , // status output for C sink FIFO
  output logic                   a_done_o         , // completion flag for A stream
  output cntrl_streamer_t        cntrl_streamer_o   // streamer control signals
);
  localparam int unsigned JMP = DW/8;

  // Registri di iterazione e offset per i flussi CSR e densi
  logic [31:0]        a_offs_d, a_offs_q;
  logic [31:0]        colid_offs_d, colid_offs_q;
  logic [31:0]        rowptr_offs_d, rowptr_offs_q;
  logic [31:0]        b_rows_offs_d, b_rows_offs_q;

  logic [15:0]        nnz_iters_d, nnz_iters_q;
  logic [15:0]        tot_a_read_d, tot_a_read_q;

  // Configurazioni e stati FIFO per ciascuno stream SpMM
  spmm_config_t a_config, colid_config, rowptr_config, b_config, c_config;
  logic         a_config_empty, colid_config_empty, rowptr_config_empty, b_config_empty, c_config_empty;
  logic         a_config_full,  colid_config_full,  rowptr_config_full,  b_config_full,  c_config_full;

  logic         start_a_streamer;

  // Condizione di completamento per lo stream dei valori A (e associati colID)
  assign a_done_o = (tot_a_read_q == a_config.tot_nnz - 1) && flgs_streamer_i.a_stream_source_flags.done;

  // -------------------------------------------------------------------------
  // FIFO di Configurazione per ciascun canale (A, ColID, RowPtr, B, C)
  // -------------------------------------------------------------------------

  // 1. FIFO Configurazione Stream A (Valori non-zero)
  spmm_config_fifo #(
    .FALL_THROUGH (0),
    .DEPTH (2),
    .dtype (spmm_config_t)
  ) i_a_config_fifo (
    .clk_i      ( clk_i                           ),
    .rst_ni     ( rst_ni                          ),
    .flush_i    ( clear_i | cntrl_scheduler_i.rst ),
    .testmode_i ( '0                              ),
    .full_o     ( a_config_full                   ),
    .empty_o    ( a_config_empty                  ),
    .usage_o    (                                 ),
    .data_i     ( config_i                        ),
    .push_i     ( config_valid_i                  ),
    .data_o     ( a_config                        ),
    .pop_i      ( a_done_o                        )
  );

  // 2. FIFO Configurazione Stream ColID (Indici di colonna)
  spmm_config_fifo #(
    .FALL_THROUGH (0),
    .DEPTH (2),
    .dtype (spmm_config_t)
  ) i_colid_config_fifo (
    .clk_i      ( clk_i                           ),
    .rst_ni     ( rst_ni                          ),
    .flush_i    ( clear_i | cntrl_scheduler_i.rst ),
    .testmode_i ( '0                              ),
    .full_o     ( colid_config_full               ),
    .empty_o    ( colid_config_empty              ),
    .usage_o    (                                 ),
    .data_i     ( config_i                        ),
    .push_i     ( config_valid_i                  ),
    .data_o     ( colid_config                    ),
    .pop_i      ( flgs_streamer_i.colID_stream_source_flags.done )
  );

  // 3. FIFO Configurazione Stream RowPtr (Puntatori di riga CSR)
  spmm_config_fifo #(
    .FALL_THROUGH (0),
    .DEPTH (2),
    .dtype (spmm_config_t)
  ) i_rowptr_config_fifo (
    .clk_i      ( clk_i                           ),
    .rst_ni     ( rst_ni                          ),
    .flush_i    ( clear_i | cntrl_scheduler_i.rst ),
    .testmode_i ( '0                              ),
    .full_o     ( rowptr_config_full              ),
    .empty_o    ( rowptr_config_empty             ),
    .usage_o    (                                 ),
    .data_i     ( config_i                        ),
    .push_i     ( config_valid_i                  ),
    .data_o     ( rowptr_config                   ),
    .pop_i      ( flgs_streamer_i.rowPtr_stream_source_flags.done )
  );

  // 4. FIFO Configurazione Stream B (Matrice densa B)
  spmm_config_fifo #(
    .FALL_THROUGH (0),
    .DEPTH (2),
    .dtype (spmm_config_t)
  ) i_b_config_fifo (
    .clk_i      ( clk_i                           ),
    .rst_ni     ( rst_ni                          ),
    .flush_i    ( clear_i | cntrl_scheduler_i.rst ),
    .testmode_i ( '0                              ),
    .full_o     ( b_config_full                   ),
    .empty_o    ( b_config_empty                  ),
    .usage_o    (                                 ),
    .data_i     ( config_i                        ),
    .push_i     ( config_valid_i                  ),
    .data_o     ( b_config                        ),
    .pop_i      ( flgs_streamer_i.b_stream_source_flags.done )
  );

  // 5. FIFO Configurazione Stream C (Sink di output)
  spmm_config_fifo #(
    .FALL_THROUGH (0),
    .DEPTH (2),
    .dtype (spmm_config_t)
  ) i_c_config_fifo (
    .clk_i      ( clk_i                           ),
    .rst_ni     ( rst_ni                          ),
    .flush_i    ( clear_i | cntrl_scheduler_i.rst ),
    .testmode_i ( '0                              ),
    .full_o     ( c_config_full                   ),
    .empty_o    ( c_config_empty                  ),
    .usage_o    (                                 ),
    .data_i     ( config_i                        ),
    .push_i     ( config_valid_i                  ),
    .data_o     ( c_config                        ),
    .pop_i      ( flgs_streamer_i.c_stream_sink_flags.done )
  );

  assign c_fifo_empty_o = c_config_empty;

  // -------------------------------------------------------------------------
  // Registri di conteggio e tracciamento trasmissioni
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : tot_a_read_register
    if (~rst_ni) begin
      tot_a_read_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        tot_a_read_q <= '0;
      end else if (flgs_streamer_i.a_stream_source_flags.done) begin
        tot_a_read_q <= tot_a_read_d;
      end
    end
  end

  assign tot_a_read_d = (tot_a_read_q == a_config.tot_nnz - 1) ? '0 : tot_a_read_q + 1;

  // -------------------------------------------------------------------------
  // Generazione dei segnali di controllo e indirizzamento per lo Streamer
  // -------------------------------------------------------------------------
  always_comb begin : address_gen_signals
    // --- A Stream Source (Valori NNZ) ---
    cntrl_streamer_o.a_stream_source_ctrl.addressgen_ctrl.base_addr   = a_config.a_addr;
    cntrl_streamer_o.a_stream_source_ctrl.addressgen_ctrl.tot_len     = a_config.tot_nnz;
    cntrl_streamer_o.a_stream_source_ctrl.addressgen_ctrl.d0_len      = a_config.tot_nnz;
    cntrl_streamer_o.a_stream_source_ctrl.addressgen_ctrl.d0_stride   = JMP;
    cntrl_streamer_o.a_stream_source_ctrl.addressgen_ctrl.d1_stride   = '0;
    cntrl_streamer_o.a_stream_source_ctrl.addressgen_ctrl.d1_len      = '0;
    cntrl_streamer_o.a_stream_source_ctrl.addressgen_ctrl.d2_stride   = '0;
    cntrl_streamer_o.a_stream_source_ctrl.addressgen_ctrl.d2_len      = '0;
    cntrl_streamer_o.a_stream_source_ctrl.addressgen_ctrl.d3_stride   = '0;
    cntrl_streamer_o.a_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 3'b001;

    // --- ColID Stream Source (Indici di colonna) ---
    cntrl_streamer_o.colID_stream_source_ctrl.addressgen_ctrl.base_addr = colid_config.colid_addr;
    cntrl_streamer_o.colID_stream_source_ctrl.addressgen_ctrl.tot_len   = colid_config.tot_nnz;
    cntrl_streamer_o.colID_stream_source_ctrl.addressgen_ctrl.d0_len    = colid_config.tot_nnz;
    cntrl_streamer_o.colID_stream_source_ctrl.addressgen_ctrl.d0_stride = JMP;
    cntrl_streamer_o.colID_stream_source_ctrl.addressgen_ctrl.d1_stride = '0;
    cntrl_streamer_o.colID_stream_source_ctrl.addressgen_ctrl.d1_len    = '0;
    cntrl_streamer_o.colID_stream_source_ctrl.addressgen_ctrl.d2_stride = '0;
    cntrl_streamer_o.colID_stream_source_ctrl.addressgen_ctrl.d2_len    = '0;
    cntrl_streamer_o.colID_stream_source_ctrl.addressgen_ctrl.d3_stride = '0;
    cntrl_streamer_o.colID_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 3'b001;

    // --- RowPtr Stream Source (Vettore puntatori CSR) ---
    cntrl_streamer_o.rowPtr_stream_source_ctrl.addressgen_ctrl.base_addr = rowptr_config.rowptr_addr;
    cntrl_streamer_o.rowPtr_stream_source_ctrl.addressgen_ctrl.tot_len   = rowptr_config.tot_ptrs;
    cntrl_streamer_o.rowPtr_stream_source_ctrl.addressgen_ctrl.d0_len    = rowptr_config.tot_ptrs;
    cntrl_streamer_o.rowPtr_stream_source_ctrl.addressgen_ctrl.d0_stride = JMP;
    cntrl_streamer_o.rowPtr_stream_source_ctrl.addressgen_ctrl.d1_stride = '0;
    cntrl_streamer_o.rowPtr_stream_source_ctrl.addressgen_ctrl.d1_len    = '0;
    cntrl_streamer_o.rowPtr_stream_source_ctrl.addressgen_ctrl.d2_stride = '0;
    cntrl_streamer_o.rowPtr_stream_source_ctrl.addressgen_ctrl.d2_len    = '0;
    cntrl_streamer_o.rowPtr_stream_source_ctrl.addressgen_ctrl.d3_stride = '0;
    cntrl_streamer_o.rowPtr_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 3'b001;

    // --- B Stream Source (Matrice densa B) ---
    cntrl_streamer_o.b_stream_source_ctrl.addressgen_ctrl.base_addr = b_config.b_addr;
    cntrl_streamer_o.b_stream_source_ctrl.addressgen_ctrl.tot_len   = b_config.b_tot_len;
    cntrl_streamer_o.b_stream_source_ctrl.addressgen_ctrl.d0_len    = b_config.b_rows_iter;
    cntrl_streamer_o.b_stream_source_ctrl.addressgen_ctrl.d0_stride = b_config.b_d0_stride;
    cntrl_streamer_o.b_stream_source_ctrl.addressgen_ctrl.d1_len    = b_config.b_cols_iter;
    cntrl_streamer_o.b_stream_source_ctrl.addressgen_ctrl.d1_stride = JMP;
    cntrl_streamer_o.b_stream_source_ctrl.addressgen_ctrl.d2_stride = '0;
    cntrl_streamer_o.b_stream_source_ctrl.addressgen_ctrl.d2_len    = '0;
    cntrl_streamer_o.b_stream_source_ctrl.addressgen_ctrl.d3_stride = '0;
    cntrl_streamer_o.b_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 3'b011;

    // --- C Stream Sink (Matrice di output C) ---
    cntrl_streamer_o.c_stream_sink_ctrl.addressgen_ctrl.base_addr   = c_config.c_addr;
    cntrl_streamer_o.c_stream_sink_ctrl.addressgen_ctrl.tot_len     = c_config.c_tot_len;
    cntrl_streamer_o.c_stream_sink_ctrl.addressgen_ctrl.d0_len      = c_config.c_rows_iter;
    cntrl_streamer_o.c_stream_sink_ctrl.addressgen_ctrl.d0_stride   = c_config.c_d0_stride;
    cntrl_streamer_o.c_stream_sink_ctrl.addressgen_ctrl.d1_len      = c_config.c_cols_iter;
    cntrl_streamer_o.c_stream_sink_ctrl.addressgen_ctrl.d1_stride   = JMP;
    cntrl_streamer_o.c_stream_sink_ctrl.addressgen_ctrl.d2_stride   = '0;
    cntrl_streamer_o.c_stream_sink_ctrl.addressgen_ctrl.d2_len      = '0;
    cntrl_streamer_o.c_stream_sink_ctrl.addressgen_ctrl.d3_stride   = '0;
    cntrl_streamer_o.c_stream_sink_ctrl.addressgen_ctrl.dim_enable_1h = 3'b011;
  end

  assign start_a_streamer = (~a_config_empty && ~a_config_full && ~a_done_o) || a_config_full;

  // -------------------------------------------------------------------------
  // Segnali di Richiesta di Avvio (req_start)
  // -------------------------------------------------------------------------
  always_comb begin : req_start_assignment
    cntrl_streamer_o.a_stream_source_ctrl.req_start      = (start_a_streamer || (tot_a_read_q != '0 && tot_a_read_q != a_config.tot_nnz)) && flgs_streamer_i.a_stream_source_flags.ready_start;
    cntrl_streamer_o.colID_stream_source_ctrl.req_start  = ~colid_config_empty  && flgs_streamer_i.colID_stream_source_flags.ready_start;
    cntrl_streamer_o.rowPtr_stream_source_ctrl.req_start = ~rowptr_config_empty && flgs_streamer_i.rowPtr_stream_source_flags.ready_start;
    cntrl_streamer_o.b_stream_source_ctrl.req_start      = ~b_config_empty      && flgs_streamer_i.b_stream_source_flags.ready_start;
    cntrl_streamer_o.c_stream_sink_ctrl.req_start        = ~c_config_empty      && flgs_streamer_i.c_stream_sink_flags.ready_start && ~flgs_streamer_i.c_stream_sink_flags.done;
  end

  // Gestione priorità e configurazioni di cast opzionali
  assign cntrl_streamer_o.c_priority = c_priority_i;

  assign cntrl_streamer_o.receive_a_stream = a_config.receive_a;
  assign cntrl_streamer_o.receive_b_stream = b_config.receive_b;
  assign cntrl_streamer_o.receive_colID_stream = colid_config.receive_colID;
  assign cntrl_streamer_o.receive_rowPtr_stream = rowptr_config.receive_rowPtr;

endmodule : spmm_memory_scheduler
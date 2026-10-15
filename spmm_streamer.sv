`include "hci_helpers.svh"

module spmm_streamer
  import spmm_pkg::*;
  import hci_package::*;
  import hwpe_stream_package::*;
#(
  parameter  int unsigned           DataW        = MaxDataW,
  parameter  int unsigned           MisalignedAccessSupport = MisalignedAccessSupportDefault,
  parameter  bit                    EnableReordering = 1'b0,
  parameter  int unsigned           Height       = MaxDim ,
  parameter  int unsigned           NumPipeRegs  = MaxPipeRegs-1,
  parameter  int unsigned           EccChunkSize = 32      ,
  parameter  mux_priority_e         MuxPriority  = MuxPriorityDefault,
  parameter hci_size_parameter_t `HCI_SIZE_PARAM(tcdm) = '0
)(
  input logic                    clk_i,
  input logic                    rst_ni,
  input logic                    test_mode_i,
  input logic                    enable_i,
  input logic                    clear_i,
  // Engine A input + HS signals (output for the streamer)
  hwpe_stream_intf_stream.source a_stream_o,
  // Engine B input + HS signals (output for the streamer)
  hwpe_stream_intf_stream.source b_stream_o,
  // Engine colID input + HS signals (output for the streamer)
  hwpe_stream_intf_stream.source colID_stream_o,
  // Engine rowPtr input + HS signals (output for the streamer)
  hwpe_stream_intf_stream.source rowPtr_stream_o,
  // Engine C output + HS signals (input for the streamer)
  hwpe_stream_intf_stream.sink   c_stream_i,

  // TCDM interface between the streamer and the memory
  hci_core_intf.initiator        tcdm      ,

  // Control signals
  input  cntrl_streamer_t        ctrl_i,
  output flgs_streamer_t         flags_o
);

localparam int unsigned EW  = `HCI_SIZE_GET_EW(tcdm);

// Non-ECC variant of tcdm size params, used for all internal (non-ECC) interfaces
localparam hci_size_parameter_t `HCI_SIZE_PARAM(ldst_tcdm) = '{
  DW:  `HCI_SIZE_GET_DW(tcdm),
  AW:  `HCI_SIZE_GET_AW(tcdm),
  BW:  `HCI_SIZE_GET_BW(tcdm),
  UW:  `HCI_SIZE_GET_UW(tcdm),
  IW:  `HCI_SIZE_GET_IW(tcdm),
  EW:  DEFAULT_EW,
  EHW: `HCI_SIZE_GET_EHW(tcdm)
};

// Here the dynamic mux for virtual_tcdm interfaces
// coming/going from/to the accelerator to/from the memory
hci_core_intf #(
`ifndef SYNTHESIS
  .WAIVE_RSP3_ASSERT ( 1'b1 ), // waive RSP-3 on memory-side of HCI FIFO
  .WAIVE_RSP5_ASSERT ( 1'b1 ), // waive RSP-5 on memory-side of HCI FIFO
`endif
  .DW  ( `HCI_SIZE_GET_DW(ldst_tcdm)  ),
  .AW  ( `HCI_SIZE_GET_AW(ldst_tcdm)  ),
  .BW  ( `HCI_SIZE_GET_BW(ldst_tcdm)  ),
  .UW  ( `HCI_SIZE_GET_UW(ldst_tcdm)  ),
  .IW  ( `HCI_SIZE_GET_IW(ldst_tcdm)  ),
  .EW  ( `HCI_SIZE_GET_EW(ldst_tcdm)  ),
  .EHW ( `HCI_SIZE_GET_EHW(ldst_tcdm) )
) ldst_tcdm ( .clk ( clk_i ) );

hci_core_intf #(
`ifndef SYNTHESIS
  .WAIVE_RSP3_ASSERT ( 1'b1 ), // waive RSP-3 on memory-side of HCI FIFO
  .WAIVE_RSP5_ASSERT ( 1'b1 ), // waive RSP-5 on memory-side of HCI FIFO
`endif
  .DW  ( `HCI_SIZE_GET_DW(ldst_tcdm)  ),
  .AW  ( `HCI_SIZE_GET_AW(ldst_tcdm)  ),
  .BW  ( `HCI_SIZE_GET_BW(ldst_tcdm)  ),
  .UW  ( `HCI_SIZE_GET_UW(ldst_tcdm)  ),
  .IW  ( `HCI_SIZE_GET_IW(ldst_tcdm)  ),
  .EW  ( `HCI_SIZE_GET_EW(ldst_tcdm)  ),
  .EHW ( `HCI_SIZE_GET_EHW(ldst_tcdm) )
) ldst_tcdm_pre_r_valid ( .clk ( clk_i ) );

hci_core_intf #(
`ifndef SYNTHESIS
  .WAIVE_RSP3_ASSERT ( 1'b1 ), // waive RSP-3 on memory-side of HCI FIFO
  .WAIVE_RSP5_ASSERT ( 1'b1 ), // waive RSP-5 on memory-side of HCI FIFO
`endif
  .DW  ( `HCI_SIZE_GET_DW(ldst_tcdm)  ),
  .AW  ( `HCI_SIZE_GET_AW(ldst_tcdm)  ),
  .BW  ( `HCI_SIZE_GET_BW(ldst_tcdm)  ),
  .UW  ( `HCI_SIZE_GET_UW(ldst_tcdm)  ),
  .IW  ( `HCI_SIZE_GET_IW(ldst_tcdm)  ),
  .EW  ( `HCI_SIZE_GET_EW(ldst_tcdm)  ),
  .EHW ( `HCI_SIZE_GET_EHW(ldst_tcdm) )
) ldst_tcdm_pre_r_id ( .clk ( clk_i ) );

if (EW > 1) begin : gen_ecc_encoder
  logic [`HCI_SIZE_GET_DW(tcdm)/EccChunkSize-1:0] data_single_err, data_multi_err;
  logic                          meta_single_err, meta_multi_err;

  hci_ecc_enc #(
    .DW ( `HCI_SIZE_GET_DW(tcdm) ),
    .`HCI_SIZE_PARAM(tcdm_target)    ( `HCI_SIZE_PARAM(ldst_tcdm) ),
    .`HCI_SIZE_PARAM(tcdm_initiator) ( `HCI_SIZE_PARAM(tcdm)      )
  ) i_ecc_enc (
    .r_data_single_err_o ( data_single_err ),
    .r_data_multi_err_o  ( data_multi_err  ),
    .r_meta_single_err_o ( meta_single_err ),
    .r_meta_multi_err_o  ( meta_multi_err  ),
    .tcdm_target         ( ldst_tcdm       ),
    .tcdm_initiator      ( tcdm            )
  );
end else begin : gen_ldst_assign
  hci_core_assign i_ldst_assign ( .tcdm_target (ldst_tcdm), .tcdm_initiator (tcdm) );
end

// Virtual internal TCDM interface splitting the upstream TCDM
hci_core_intf #(
`ifndef SYNTHESIS
  .WAIVE_RSP3_ASSERT ( 1'b1 ), // waive RSP-3 on memory-side of HCI FIFO
  .WAIVE_RSP5_ASSERT ( 1'b1 ), // waive RSP-5 on memory-side of HCI FIFO
  .WAIVE_RQ3_ASSERT  ( 1'b1 ),
  .WAIVE_RQ4_ASSERT  ( 1'b1 ),
`endif
  .DW  ( `HCI_SIZE_GET_DW(ldst_tcdm)  ),
  .AW  ( `HCI_SIZE_GET_AW(ldst_tcdm)  ),
  .BW  ( `HCI_SIZE_GET_BW(ldst_tcdm)  ),
  .UW  ( `HCI_SIZE_GET_UW(ldst_tcdm)  ),
  .IW  ( `HCI_SIZE_GET_IW(ldst_tcdm)  ),
  .EW  ( `HCI_SIZE_GET_EW(ldst_tcdm)  ),
  .EHW ( `HCI_SIZE_GET_EHW(ldst_tcdm) )
) virt_tcdm [0:NumStreamSources] ( .clk ( clk_i ) );

// LD/ST arbitration onto the shared TCDM port.
//  * EnableReordering = 0: fixed-priority, single-outstanding-request arbiter
//    (spmm_mux) followed by a 1-cycle-latency r_valid filter, as before.
//  * EnableReordering = 1: each of the A/B/ColID/RowPtr load channels gets its own
//    hci_core_rob so several requests can be in flight at once on that channel;
//    the (already in-order) C/store and spare channels pass through unchanged.
//    All channels are then arbitrated out-of-order (hci_core_mux_ooo).
if (EnableReordering) begin : gen_outstanding_ldst_mux

  // Number of unique user-IDs the ROB and the out-of-order mux can track;
  localparam int unsigned UW     = `HCI_SIZE_GET_UW(ldst_tcdm);
  localparam int unsigned ROB_NW = 1 << UW;

  hci_core_intf #(
  `ifndef SYNTHESIS
    .WAIVE_RSP3_ASSERT ( 1'b1 ),
    .WAIVE_RSP5_ASSERT ( 1'b1 ),
    .WAIVE_RQ3_ASSERT  ( 1'b1 ),
    .WAIVE_RQ4_ASSERT  ( 1'b1 ),
  `endif
    .DW  ( `HCI_SIZE_GET_DW(ldst_tcdm)  ),
    .AW  ( `HCI_SIZE_GET_AW(ldst_tcdm)  ),
    .BW  ( `HCI_SIZE_GET_BW(ldst_tcdm)  ),
    .UW  ( `HCI_SIZE_GET_UW(ldst_tcdm)  ),
    .IW  ( `HCI_SIZE_GET_IW(ldst_tcdm)  ),
    .EW  ( `HCI_SIZE_GET_EW(ldst_tcdm)  ),
    .EHW ( `HCI_SIZE_GET_EHW(ldst_tcdm) )
  ) virt_tcdm_rob [0:NumStreamSources] ( .clk ( clk_i ) );

  for (genvar i = 0; i < NumStreamSources; i++) begin : gen_channel_rob
    hci_core_rob #(
      .ROB_NW               ( ROB_NW                     ),
      .`HCI_SIZE_PARAM(out) ( `HCI_SIZE_PARAM(ldst_tcdm) )
    ) i_streamer_rob (
      .clk_i  ( clk_i            ),
      .rst_ni ( rst_ni           ),
      .in     ( virt_tcdm[i]     ),
      .out    ( virt_tcdm_rob[i] )
    );
  end

  // The C/store channel does not need reordering: pass it through to the
  // out-of-order mux unchanged.
  hci_core_assign i_rob_bypass ( .tcdm_target (virt_tcdm[NumStreamSources]), .tcdm_initiator (virt_tcdm_rob[NumStreamSources]) );

  logic [NumStreamSources:0][$clog2(NumStreamSources+1)-1:0] priority_encoding;
  assign priority_encoding[0] = 0;
  assign priority_encoding[1] = 1;
  assign priority_encoding[2] = 2;
  assign priority_encoding[3] = 3;
  assign priority_encoding[4] = 4;

  hci_core_mux_ooo #(
    .NB_CHAN              ( NumStreamSources+1         ),
    .`HCI_SIZE_PARAM(out) ( `HCI_SIZE_PARAM(ldst_tcdm) )
  ) i_mux (
    .clk_i            ( clk_i             ),
    .rst_ni           ( rst_ni            ),
    .clear_i          ( clear_i           ),
    .priority_force_i ( 1'b1              ),
    .priority_i       ( priority_encoding ),
    .in               ( virt_tcdm_rob     ),
    .out              ( ldst_tcdm         )
  );

end else begin : gen_fixed_priority_ldst_mux

if (MuxPriority == MUX_PRIORITY_STATIC) begin : static_mux_gen
  spmm_mux #(
    .NB_CHAN   (NumStreamSources+1),
    .`HCI_SIZE_PARAM(out) ( `HCI_SIZE_PARAM(ldst_tcdm) )
  ) i_mux (
    .clk_i      ( clk_i                 ),
    .rst_ni     ( rst_ni                ),
    .clear_i    ( clear_i               ),
    .in         ( virt_tcdm             ),
    .out        ( ldst_tcdm_pre_r_valid )
  );
end
else begin
  hci_core_mux_ooo #(
    .NB_CHAN              ( NumStreamSources+1         ),
    .`HCI_SIZE_PARAM(out) ( `HCI_SIZE_PARAM(ldst_tcdm) )
  ) i_mux (
    .clk_i            ( clk_i                 ),
    .rst_ni           ( rst_ni                ),
    .clear_i          ( clear_i               ),
    .priority_force_i ( '0                    ),
    .priority_i       ( '0                    ),
    .in               ( virt_tcdm             ),
    .out              ( ldst_tcdm_pre_r_valid )
  );
end

hci_core_r_valid_filter #(
  .`HCI_SIZE_PARAM(tcdm_target)   ( `HCI_SIZE_PARAM(ldst_tcdm) )
) i_tcdm_r_valid_filter (
    .clk_i          (  clk_i                 ),
    .rst_ni         (  rst_ni                ),
    .clear_i        (  clear_i               ),
    .enable_i       (  1'b1                  ),
    .tcdm_target    (  ldst_tcdm_pre_r_valid ),
    .tcdm_initiator (  ldst_tcdm_pre_r_id    )
);

hci_core_r_id_filter #(
  .`HCI_SIZE_PARAM(tcdm_target)   (   `HCI_SIZE_PARAM(ldst_tcdm) )
) i_load_r_id_filter (
  .clk_i          ( clk_i                 ),
  .rst_ni         ( rst_ni                ),
  .clear_i        ( clear_i               ),
  .enable_i       ( 1'b1                  ),
  .tcdm_target    ( ldst_tcdm_pre_r_id    ),
  .tcdm_initiator ( ldst_tcdm             )
);


end

/************************************ Store Channel *************************************/
/* The store channel of the streamer connects the incoming stream interface (C stream)  *
 * to an HCI core sink module that translates the stream into a TCDM protocol. This     *
 * sink module then connects to a TCDM FIFO that eventually connects to the store       *
 * side (virt_tcdm[NumStreamSources]) of the LD/ST multiplexer.                         */

// Store interface FIFO buses.
hci_core_intf #(
`ifndef SYNTHESIS
  .WAIVE_RSP3_ASSERT ( 1'b1 ), // waive RSP-3 on memory-side of HCI FIFO
  .WAIVE_RSP5_ASSERT ( 1'b1 ),  // waive RSP-5 on memory-side of HCI FIFO
`endif
  .DW  ( `HCI_SIZE_GET_DW(ldst_tcdm)  ),
  .AW  ( `HCI_SIZE_GET_AW(ldst_tcdm)  ),
  .BW  ( `HCI_SIZE_GET_BW(ldst_tcdm)  ),
  .UW  ( `HCI_SIZE_GET_UW(ldst_tcdm)  ),
  .IW  ( `HCI_SIZE_GET_IW(ldst_tcdm)  ),
  .EW  ( `HCI_SIZE_GET_EW(ldst_tcdm)  ),
  .EHW ( `HCI_SIZE_GET_EHW(ldst_tcdm) )
) c_fifo_d ( .clk ( clk_i ) );
`HCI_INTF_EXPLICIT_PARAM(c_fifo_q, clk_i, `HCI_SIZE_PARAM(ldst_tcdm));

// Sink module that turns the incoming Z stream into TCDM.
hci_core_sink         #(
  .MISALIGNED_ACCESSES ( MisalignedAccessSupport ),
  .`HCI_SIZE_PARAM(tcdm) ( `HCI_SIZE_PARAM(ldst_tcdm) )
) i_stream_sink        (
  .clk_i               ( clk_i                       ),
  .rst_ni              ( rst_ni                      ),
  .test_mode_i         ( test_mode_i                 ),
  .clear_i             ( clear_i                     ),
  .enable_i            ( enable_i                    ),
  .tcdm                ( c_fifo_d                    ),
  .stream              ( c_stream_i                  ),
  .ctrl_i              ( ctrl_i.c_stream_sink_ctrl   ),
  .flags_o             ( flags_o.c_stream_sink_flags )
);

flags_fifo_t store_fifo_flags;

// HCI store fifo.
hci_core_fifo #(
  .FIFO_DEPTH                      ( EnableReordering ? Height*(NumPipeRegs+1) : 2 ),
  .`HCI_SIZE_PARAM(tcdm_initiator) ( `HCI_SIZE_PARAM(ldst_tcdm) )
) i_store_fifo (
  .clk_i          ( clk_i            ),
  .rst_ni         ( rst_ni           ),
  .clear_i        ( clear_i          ),
  .flags_o        ( store_fifo_flags ),
  .tcdm_target    ( c_fifo_d         ),
  .tcdm_initiator ( c_fifo_q         )
);

assign flags_o.store_fifo_empty = store_fifo_flags.empty;

// Assigning the store FIFO output to the store side of the y/z multiplexer.
hci_core_assign i_store_assign ( .tcdm_target (c_fifo_q), .tcdm_initiator (virt_tcdm[NumStreamSources]) );

/**************************************** Load Channel ****************************************/
/* The load channel of the streamer connects the incoming TCDM interface to four different   *
 * stream interfaces: A stream (ID: 0), B stream (ID: 1), colId stream (ID: 2), Rowtr stream (ID: 3). *
 * The load side (virt_tcdm[0]) of the LD/ST multiplexer connects to another multiplexer that splits the    *
 * icoming TCDM bus into four TCDM interfaces (A, B, colId, Rowtr). Each interface connects to its  *
 * own FIFO, and then to a dedicated HCI core source unit used to translate the  *
 * incoming TCDM protocls into stream.                                                        */

// Virtual TCDM interfaces
// A   -> virt_tcdm[0]
// B   -> virt_tcdm[1]
// ColId -> virt_tcdm[2]
// Rowtr -> virt_tcdm[3]

// One TCDM FIFO and one HCI core source unit per stream channel.
hci_core_intf #(
`ifndef SYNTHESIS
  .WAIVE_RSP3_ASSERT ( 1'b1 ), // waive RSP-3 on memory-side of HCI FIFO
  .WAIVE_RSP5_ASSERT ( 1'b1 ),  // waive RSP-5 on memory-side of HCI FIFO
  .WAIVE_RQ4_ASSERT  ( 1'b1 ),
`endif
  .DW  ( `HCI_SIZE_GET_DW(ldst_tcdm)  ),
  .AW  ( `HCI_SIZE_GET_AW(ldst_tcdm)  ),
  .BW  ( `HCI_SIZE_GET_BW(ldst_tcdm)  ),
  .UW  ( `HCI_SIZE_GET_UW(ldst_tcdm)  ),
  .IW  ( `HCI_SIZE_GET_IW(ldst_tcdm)  ),
  .EW  ( `HCI_SIZE_GET_EW(ldst_tcdm)  ),
  .EHW ( `HCI_SIZE_GET_EHW(ldst_tcdm) )
) load_fifo_d [0:NumStreamSources-1] ( .clk ( clk_i ) );

hci_core_intf #(
`ifndef SYNTHESIS
  .WAIVE_RSP3_ASSERT ( 1'b1 ),
  .WAIVE_RSP5_ASSERT ( 1'b1 ),
  .WAIVE_RQ4_ASSERT  ( 1'b1 ),
`endif
  .DW  ( `HCI_SIZE_GET_DW(ldst_tcdm)  ),
  .AW  ( `HCI_SIZE_GET_AW(ldst_tcdm)  ),
  .BW  ( `HCI_SIZE_GET_BW(ldst_tcdm)  ),
  .UW  ( `HCI_SIZE_GET_UW(ldst_tcdm)  ),
  .IW  ( `HCI_SIZE_GET_IW(ldst_tcdm)  ),
  .EW  ( `HCI_SIZE_GET_EW(ldst_tcdm)  ),
  .EHW ( `HCI_SIZE_GET_EHW(ldst_tcdm) )
) load_fifo_q [0:NumStreamSources-1] ( .clk ( clk_i ) );

hwpe_stream_intf_stream #( .DATA_WIDTH ( DataW ) ) out_stream [0:NumStreamSources-1] ( .clk( clk_i ) );

hci_package::hci_streamer_ctrl_t        [NumStreamSources-1:0] source_ctrl;
hci_package::hci_streamer_flags_t       [NumStreamSources-1:0] source_flags;

// Assign input control buses to the relative ID in the vector.
assign source_ctrl[AsourceStreamId]      = ctrl_i.a_stream_source_ctrl;
assign source_ctrl[BsourceStreamId]      = ctrl_i.b_stream_source_ctrl;
assign source_ctrl[ColIDsourceStreamId]      = ctrl_i.colID_stream_source_ctrl;
assign source_ctrl[RowPtrsourceStreamId]      = ctrl_i.rowPtr_stream_source_ctrl;

for (genvar i = 0; i < NumStreamSources; i++) begin: gen_tcdm2stream

  logic source_enable;

  hci_core_assign i_load_assign ( .tcdm_target (load_fifo_d[i]), .tcdm_initiator (virt_tcdm[i]) );

  // hci_core_fifo can retract a request it already raised without a grant
  // (a documented RQ-4 protocol violation, harmless when grants are never
  // delayed) whenever its response-side fill level changes while a request
  // is pending - which happens routinely once the ROB lets requests wait
  // for a grant across many cycles. The ROB already buffers/reorders on
  // this channel, so the FIFO's buffering is redundant here: skip it and
  // wire the cast unit straight to the ROB when outstanding is enabled.
  if (EnableReordering) begin : gen_no_load_tcdm_fifo
    hci_core_assign i_load_tcdm_bypass ( .tcdm_target (load_fifo_q[i]), .tcdm_initiator (load_fifo_d[i]) );
  end else begin : gen_load_tcdm_fifo
    hci_core_fifo #(
      .FIFO_DEPTH  ( 4  ), // to avoid protocol violations, as the consumer has a throughput
                           // of 1 packet over 4 cycles, we need a depth of 4 elements.
      .`HCI_SIZE_PARAM(tcdm_initiator) ( `HCI_SIZE_PARAM(ldst_tcdm) )
    ) i_load_tcdm_fifo (
      .clk_i          ( clk_i          ),
      .rst_ni         ( rst_ni         ),
      .clear_i        ( clear_i        ),
      .flags_o        (                ),
      .tcdm_target    ( load_fifo_q[i] ),
      .tcdm_initiator ( load_fifo_d[i] )
    );
  end

  if (i == BsourceStreamId) begin
    assign source_enable = enable_i & ~ctrl_i.receive_b_stream;
  end else if (i == AsourceStreamId) begin
    assign source_enable = enable_i & ~ctrl_i.receive_a_stream;
  end else if (i == ColIDsourceStreamId) begin
    assign source_enable = enable_i & ~ctrl_i.receive_colID_stream;
  end else if (i == RowPtrsourceStreamId) begin
    assign source_enable = enable_i & ~ctrl_i.receive_rowPtr_stream;
  end else begin
    assign source_enable = enable_i;
  end

  hci_core_source       #(
    .MISALIGNED_ACCESSES   ( MisalignedAccessSupport ),
    .`HCI_SIZE_PARAM(tcdm) ( `HCI_SIZE_PARAM(ldst_tcdm) ),
    .RESP_FIFO_DEPTH       ( EnableReordering ? Height*(NumPipeRegs+1) : 0 )
  ) i_stream_source      (
    .clk_i               ( clk_i           ),
    .rst_ni              ( rst_ni          ),
    .test_mode_i         ( test_mode_i     ),
    .clear_i             ( clear_i         ),
    .enable_i            ( source_enable   ),
    .tcdm                ( load_fifo_q[i] ),
    .stream              ( out_stream[i]   ),
    .ctrl_i              ( source_ctrl[i]  ),
    .flags_o             ( source_flags[i] )
  );
end

// Assign flags in the vector to the relative output buses.
assign flags_o.a_stream_source_flags = source_flags[AsourceStreamId];
assign flags_o.colID_stream_source_flags = source_flags[ColIDsourceStreamId];
assign flags_o.rowPtr_stream_source_flags = source_flags[RowPtrsourceStreamId];
assign flags_o.b_stream_source_flags = source_flags[BsourceStreamId];

// Assign resulting streams.
hwpe_stream_assign i_astream_assign ( .push_i( out_stream[AsourceStreamId] ) ,
                                      .pop_o ( a_stream_o                  ) );

hwpe_stream_assign i_colIDstream_assign ( .push_i( out_stream[ColIDsourceStreamId] ) ,
                                      .pop_o ( colID_stream_o                  ) );

hwpe_stream_assign i_rowPtrstream_assign ( .push_i( out_stream[RowPtrsourceStreamId] ) ,
                                      .pop_o ( rowPtr_stream_o                  ) );

hwpe_stream_assign i_bstream_assign ( .push_i( out_stream[BsourceStreamId] ) ,
                                      .pop_o ( b_stream_o                  ) );

`ifndef SYNTHESIS
`ifndef VERILATOR
`ifndef VCS
initial begin
  tcdm_size_check_dw : assert(`HCI_SIZE_PARAM(tcdm).DW == ((MisalignedAccessSupport == 1) ? (DataW + 32) : DataW));
end
`endif
`endif
`endif

endmodule : spmm_streamer

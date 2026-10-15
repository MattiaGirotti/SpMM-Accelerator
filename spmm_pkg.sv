import hci_package::*;
import hwpe_stream_package::*;

package redmule_pkg;
  parameter int unsigned MaxDim               = 32;

  parameter int unsigned NumStreamSources     = 4; // A, B, ColID, RowPtr

  parameter int unsigned AsourceStreamId      = 0;
  parameter int unsigned BsourceStreamId      = 1;
  parameter int unsigned ColIDsourceStreamId      = 2;
  parameter int unsigned RowPtrsourceStreamId      = 3;


  typedef struct packed {
    hci_package::hci_streamer_ctrl_t        a_stream_source_ctrl;
    hci_package::hci_streamer_ctrl_t        b_stream_source_ctrl;
    hci_package::hci_streamer_ctrl_t        colID_stream_source_ctrl;
    hci_package::hci_streamer_ctrl_t        rowPtr_stream_source_ctrl;
    hci_package::hci_streamer_ctrl_t        c_stream_sink_ctrl;
    logic                                   c_priority;
    logic                                   receive_a_stream;
    logic                                   receive_b_stream;
    logic                                   receive_colID_stream;
    logic                                   receive_rowPtr_stream;
  } cntrl_streamer_t;

  typedef struct packed {
    logic                             store_fifo_empty;
    hci_package::hci_streamer_flags_t a_stream_source_flags;
    hci_package::hci_streamer_flags_t b_stream_source_flags;
    hci_package::hci_streamer_flags_t colID_stream_source_flags;
    hci_package::hci_streamer_flags_t rowPtr_stream_source_flags;
    hci_package::hci_streamer_flags_t c_stream_sink_flags;
  } flgs_streamer_t;

  typedef struct packed {
    logic [31:0] a_addr;
    logic [31:0] colid_addr;
    logic [31:0] rowptr_addr;
    logic [31:0] b_addr;
    logic [31:0] c_addr;
    logic [31:0] tot_nnz;
    logic [31:0] tot_ptrs;
    logic [31:0] b_tot_len;
    logic [31:0] b_rows_iter;
    logic [31:0] b_cols_iter;
    logic [31:0] b_d0_stride;
    logic        receive_a;
    logic        receive_b;
    logic        receive_colID;
    logic        receive_rowPtr;
  } spmm_config_t;

  typedef struct packed {
    logic rst;
  } cntrl_scheduler_t;

  typedef struct packed {
    logic idle;
  } cntrl_flags_t;
  
  typedef struct packed {
    logic load;
  } a_buffer_ctrl_t;
  
endpackage
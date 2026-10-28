// ============================================================================
// Module: spmm_pkg.sv
// Description: Package definitions for the CSR SpMM Accelerator
// ============================================================================

package spmm_pkg;

  // Struct di configurazione del job proveniente dai registri di controllo
  typedef struct packed {
    logic [31:0] row_ptr_base_addr;
    logic [31:0] b_base_addr;
    logic [31:0] a_base_addr;
    logic [31:0] col_id_base_addr;
    logic [31:0] c_base_addr;
    logic [15:0] row_ptr_num_words;
    logic [15:0] b_num_words;
  } spmm_config_t;

  parameter int unsigned SPMM_DEFAULT_DW = 8;

endpackage : spmm_pkg
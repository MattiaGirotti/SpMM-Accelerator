// ============================================================================
// Module: spmm_target_decoder
// Description: Memory-mapped target interface and register file wrapper for 
//              the CSR SpMM Accelerator, following the RedMulE architectural pattern.
// ============================================================================

module spmm_target_decoder
  import spmm_pkg::*;
  import spmm_regif_pkg::*;
#(
  parameter int unsigned OpIdWidth = 4
)(
  input  logic                clk_i,
  input  logic                rst_ni,
  input  logic                clear_i,
  output logic                target_clear_o,
  input  logic                config_ready_i,
  input  logic                op_done_i,
  output logic                config_valid_o,
  output spmm_config_t        config_o,
  
  // Target peripheral bus interface (from PULP interconnect)
  hwpe_ctrl_intf_periph.slave target
);

  // Target internal signals
  logic                                   job_trigger;
  logic                                   job_done;
  logic [31:0]                            job_status;
  spmm_regif__hwpe_ctrl_job_indep__out_t  job_indep_regs;
  logic                                   job_dep_regs_valid;
  spmm_regif__hwpe_ctrl_job_dep__out_t    job_dep_regs;

  // CPU interface signals for register file ("PeakRDL passthrough")
  logic        target_cpuif_req;
  logic        target_cpuif_req_is_wr;
  logic [31:0] target_cpuif_addr;
  logic [31:0] target_cpuif_wr_data;
  logic [31:0] target_cpuif_wr_biten;
  logic        target_cpuif_req_stall_wr;
  logic        target_cpuif_req_stall_rd;
  logic        target_cpuif_rd_ack;
  logic        target_cpuif_rd_err;
  logic [31:0] target_cpuif_rd_data;
  logic        target_cpuif_wr_ack;
  logic        target_cpuif_wr_err;

  spmm_regif__in_t  hwif_in;
  spmm_regif__in_t  hwif_in_target;
  spmm_regif__out_t hwif_out;

  /* HWPE Controller Target Port */
  hwpe_ctrl_target #(
    .NB_CONTEXT            ( 2                                       ),
    .ID_WIDTH              ( OpIdWidth                               ),
    .ADDR_WIDTH            ( 8                                       ),
    .hwpe_ctrl_regif_in_t  ( spmm_regif__in_t                        ),
    .hwpe_ctrl_regif_out_t ( spmm_regif__out_t                       ),
    .hwpe_ctrl_job_indep_t ( spmm_regif__hwpe_ctrl_job_indep__out_t  ),
    .hwpe_ctrl_job_dep_t   ( spmm_regif__hwpe_ctrl_job_dep__out_t    )
  ) i_target (
    .clk_i                 ( clk_i              ),
    .rst_ni                ( rst_ni             ),
    .clear_o               ( target_clear_o     ),
    .target                ( target             ),
    .job_trigger_o         ( job_trigger        ),
    .job_done_i            ( job_done           ),
    .job_status_i          ( job_status         ),
    .job_indep_regs_o      ( job_indep_regs     ),
    .job_dep_regs_valid_o  ( job_dep_regs_valid ),
    .job_dep_regs_o        ( job_dep_regs       ),
    .target_cpuif_req_o          ( target_cpuif_req          ),
    .target_cpuif_req_is_wr_o    ( target_cpuif_req_is_wr    ),
    .target_cpuif_addr_o         ( target_cpuif_addr         ),
    .target_cpuif_wr_data_o      ( target_cpuif_wr_data      ),
    .target_cpuif_wr_biten_o     ( target_cpuif_wr_biten     ),
    .target_cpuif_req_stall_wr_i ( target_cpuif_req_stall_wr ),
    .target_cpuif_req_stall_rd_i ( target_cpuif_req_stall_rd ),
    .target_cpuif_rd_ack_i       ( target_cpuif_rd_ack       ),
    .target_cpuif_rd_err_i       ( target_cpuif_rd_err       ),
    .target_cpuif_rd_data_i      ( target_cpuif_rd_data      ),
    .target_cpuif_wr_ack_i       ( target_cpuif_wr_ack       ),
    .target_cpuif_wr_err_i       ( target_cpuif_wr_err       ),
    .hwif_in               ( hwif_in_target     ),
    .hwif_out              ( hwif_out           )
  );

  /* SpMM SystemRDL-generated Register Interface (`spmm_regif`) */
  spmm_regif i_regif (
    .clk                  ( clk_i                     ),
    .arst_n               ( rst_ni                    ),
    .s_cpuif_req          ( target_cpuif_req          ),
    .s_cpuif_req_is_wr    ( target_cpuif_req_is_wr    ),
    .s_cpuif_addr         ( target_cpuif_addr         ),
    .s_cpuif_wr_data      ( target_cpuif_wr_data      ),
    .s_cpuif_wr_biten     ( target_cpuif_wr_biten     ),
    .s_cpuif_req_stall_wr ( target_cpuif_req_stall_wr ),
    .s_cpuif_req_stall_rd ( target_cpuif_req_stall_rd ),
    .s_cpuif_rd_ack       ( target_cpuif_rd_ack       ),
    .s_cpuif_rd_err       ( target_cpuif_rd_err       ),
    .s_cpuif_rd_data      ( target_cpuif_rd_data      ),
    .s_cpuif_wr_ack       ( target_cpuif_wr_ack       ),
    .s_cpuif_wr_err       ( target_cpuif_wr_err       ),
    .hwif_in              ( hwif_in                   ),
    .hwif_out             ( hwif_out                  )
  );

  assign job_done = op_done_i;
  assign config_valid_o = job_trigger;

  // Gestione dello stato del Job (attivo/occupato)
  always_ff @(posedge clk_i or negedge rst_ni) begin : job_status_trigger
    if (~rst_ni) begin
      job_status <= '0;
    end else begin
      if (clear_i | target_clear_o) begin
        job_status <= '0;
      end else if (job_trigger & config_ready_i) begin
        job_status <= 32'h1;
      end else if (op_done_i) begin
        job_status <= '0;
      end
    end
  end

  // Mappatura dei campi di configurazione letti dal register file verso la struct `config_o`
  assign config_o.row_ptr_base_addr = hwif_out.hwpe_job_dep.row_ptr_addr.row_ptr_base_addr.value;
  assign config_o.b_base_addr       = hwif_out.hwpe_job_dep.b_addr.b_base_addr.value;
  assign config_o.a_base_addr       = hwif_out.hwpe_job_dep.a_addr.a_base_addr.value;
  assign config_o.col_id_base_addr  = hwif_out.hwpe_job_dep.col_id_addr.col_id_base_addr.value;
  assign config_o.c_base_addr       = hwif_out.hwpe_job_dep.c_addr.c_base_addr.value;
  assign config_o.row_ptr_num_words = hwif_out.hwpe_job_dep.lengths.row_ptr_num_words.value[15:0];
  assign config_o.b_num_words       = hwif_out.hwpe_job_dep.lengths.b_num_words.value[15:0];

  // Contatori ID operazione (op_id) per il tracciamento software con istruzioni MOPCNT
  logic [OpIdWidth-1:0] op_id_counter_in_q, op_id_counter_out_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : op_id_counter_in
    if (~rst_ni) begin
      op_id_counter_in_q <= 0;
    end else begin
      if (clear_i | target_clear_o) begin
        op_id_counter_in_q <= 0;
      end else if (job_trigger) begin
        op_id_counter_in_q <= op_id_counter_in_q + 1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : op_id_counter_out
    if (~rst_ni) begin
      op_id_counter_out_q <= '1;
    end else begin
      if (clear_i | target_clear_o) begin
        op_id_counter_out_q <= '1;
      end else if (op_done_i) begin
        op_id_counter_out_q <= op_id_counter_out_q + 1;
      end
    end
  end

  // Combinazione dei segnali di ingresso verso il register file (es. mopcnt)
  always_comb begin
    hwif_in = hwif_in_target;
    hwif_in.hwpe_job_dep.mopcnt.op_id_cnt.next = op_id_counter_out_q;
  end

endmodule: spmm_target_decoder
// ============================================================================
// Module: spmm_ctrl
// Description: Custom SpMM Controller (RedMulE-inspired, Tiler-free)
//              Orchestrates memory loading, computation, and result storing.
// ============================================================================

import spmm_pkg::*;
import hwpe_ctrl_package::*;

module spmm_ctrl #(
  parameter int unsigned DataW            = 32,
  parameter bit          EnableReordering = 1'b0
)(
  input  logic                    clk_i             ,
  input  logic                    rst_ni            ,
  input  logic                    test_mode_i       ,
  output logic                    busy_o            ,
  input  logic                    target_clear_i    ,
  output logic                    clear_o           ,
  output logic                    evt_o             ,
  input  spmm_config_t            config_i          ,
  output spmm_config_t            config_o          ,
  input  logic                    start_cfg_i       ,
  input logic                     fifo_empty_i         ,
  input  flgs_streamer_t          flgs_streamer_i   ,
  // Status inputs from schedulers
  input  logic                    scheduler_done_i  , // from compute scheduler (scheduler.sv done_o)
  // Control outputs
  output logic                    scheduler_start_o,
  output cntrl_scheduler_t        cntrl_scheduler_o ,
  output cntrl_flags_t            cntrl_flags_o
);

  logic latch_clear;

  // FSM States for SpMM control sequence
  typedef enum logic [2:0] {
    SPMM_LATCH_RST,
    SPMM_IDLE,
    SPMM_COMPUTING,
    SPMM_STORE_C,
    SPMM_FINISHED
  } spmm_ctrl_state_e;

  spmm_ctrl_state_e current, next;

  // -------------------------------------------------------------------------
  // State Register
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : state_register
    if (~rst_ni) begin
       current <= SPMM_LATCH_RST;
    end else if (target_clear_i) begin
       current <= SPMM_LATCH_RST;
    end else begin
       current <= next;
    end
  end

  // -------------------------------------------------------------------------
  // Slave Start Edge / Pulse Handler
  // -------------------------------------------------------------------------
  logic slave_start;
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      slave_start <= 1'b0;
    end else if (target_clear_i) begin
      slave_start <= 1'b0;
    end else begin
      if (start_cfg_i)
        slave_start <= 1'b1;
      else if (current == SPMM_FINISHED)
        slave_start <= 1'b0;
    end
  end

  // Since the tiler is removed, configuration passes directly
  assign config_o = config_i;

  // -------------------------------------------------------------------------
  // Control & Status Signal Assignments
  // -------------------------------------------------------------------------
  assign latch_clear           = (current == SPMM_LATCH_RST);
  assign clear_o               = target_clear_i || latch_clear || (current == SPMM_FINISHED);


  // Keep accelerator marked as busy during active operation states
  assign busy_o                = slave_start | (current != SPMM_LATCH_RST && current != SPMM_IDLE);
  
  assign cntrl_scheduler_o.rst        = (current == SPMM_FINISHED);

  // -------------------------------------------------------------------------
  // Controller FSM
  // -------------------------------------------------------------------------
  always_comb begin : spmm_controller_fsm
    cntrl_flags_o.idle    = 1'b0;
    next                  = current;
    scheduler_start_o     = 1'b0;

    case (current)
      SPMM_LATCH_RST: begin
        cntrl_flags_o.idle = 1'b1;
        next = SPMM_IDLE;
      end

      SPMM_IDLE: begin
        cntrl_flags_o.idle = 1'b1;
        if (slave_start || test_mode_i) begin
          next = SPMM_COMPUTING;
        end
      end

      SPMM_COMPUTING: begin
        scheduler_start_o = 1'b1;
        if (scheduler_done_i) begin
          next = SPMM_STORE_C;
        end
      end

      SPMM_STORE_C: begin
        // Wait for the C stream sink and store FIFO to finish pushing results back to memory
        if (flgs_streamer_i.c_stream_sink_flags.ready_start && fifo_empty_i && flgs_streamer_i.store_fifo_empty) begin
          next = SPMM_FINISHED;
        end
      end

      SPMM_FINISHED: begin
        next = SPMM_IDLE;
      end

      default: next = SPMM_IDLE;
    endcase
  end

  // Event generation pulse upon successful completion
  assign evt_o = flgs_streamer_i.c_stream_sink_flags.done;

endmodule : spmm_ctrl
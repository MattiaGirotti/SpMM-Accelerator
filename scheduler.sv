// ============================================================================
// Module: scheduler
// Description: FSM Scheduler for CSR SpMM Accelerator
// ============================================================================

module scheduler #(
    parameter int unsigned DATA_WIDTH      = 8,
    parameter int unsigned NUM_MACS        = 4,
    parameter int unsigned NUM_ROWS        = 4,
    parameter int unsigned TOTAL_NNZ       = 64,
    parameter int unsigned TOTAL_PTRS      = 65,
    parameter int unsigned DATA_WIDTH_OUT  = 32,
    parameter bit          REGISTERED_READ = 0
)(
    input  logic                                                clk_i,
    input  logic                                                rst_ni,
    input  logic                                                clear_i,

    // --- Control Interface ---
    input  logic                                                start_i,
    output logic                                                busy_o,
    output logic                                                done_o,

    // --- Interface to row_ptr_buffer ---
    output logic [$clog2(TOTAL_PTRS-1)-1:0]                    row_ptr_read_addr_o,
    input  logic [7:0]                                          row_ptr_start_i,
    input  logic [7:0]                                          row_ptr_end_i,

    // --- Interface to colID_buffer ---
    output logic [$clog2(TOTAL_NNZ)-1:0]                       col_id_read_addr_o,
    input  logic [DATA_WIDTH-1:0]                               col_id_i,

    // --- Interface to a_buffer ---
    output logic [$clog2(TOTAL_NNZ)-1:0]                       a_read_addr_o,

    // --- Interface to b_buffer ---
    output logic [$clog2(NUM_ROWS)-1:0]                         b_read_row_addr_o,

    // --- Interface to c_buffer ---
    output logic                                                c_write_en_o,
    output logic [$clog2(NUM_ROWS)-1:0]                         c_write_row_addr_o,
    
    // --- Datapath Input Handshake Channel ---
    output logic                                                dp_in_valid_o,
    input  logic                                                dp_in_ready_i,
    output logic [7:0]                                          dp_nnz_iterations_o,

    // --- Datapath Output Handshake Channel ---
    input  logic                                                dp_out_valid_i,
    output logic                                                dp_out_ready_o,
    input  logic                                                dp_matrix_end_i
);

    typedef enum logic [2:0] {
        IDLE,
        FETCH_ROW_PTR,
        CALC_NNZ,
        WAIT_SCM_ADDR,
        PROCESS_NNZ,
        WAIT_DP_OUT,
        STORE_C,
        CHECK_DONE
    } state_e;

    state_e current_state, next_state;

    // Internal Registers & Pointers
    logic [$clog2(NUM_ROWS)-1:0] row_idx_q, row_idx_d;
    logic [7:0]                  nnz_count_q, nnz_count_d;
    logic [7:0]                  nnz_total_q, nnz_total_d;
    logic [7:0]                  global_nnz_ptr_q, global_nnz_ptr_d;
    logic [DATA_WIDTH-1:0]       col_id_q, col_id_d;

    logic dp_in_hs;
    logic dp_out_hs;

    assign dp_in_hs  = dp_in_valid_o && dp_in_ready_i;
    assign dp_out_hs = dp_out_valid_i && dp_out_ready_o;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            current_state    <= IDLE;
            row_idx_q        <= '0;
            nnz_count_q      <= '0;
            nnz_total_q      <= '0;
            global_nnz_ptr_q <= '0;
            col_id_q         <= '0;
        end else if (clear_i) begin
            current_state    <= IDLE;
            row_idx_q        <= '0;
            nnz_count_q      <= '0;
            nnz_total_q      <= '0;
            global_nnz_ptr_q <= '0;
            col_id_q         <= '0;
        end else begin
            current_state    <= next_state;
            row_idx_q        <= row_idx_d;
            nnz_count_q      <= nnz_count_d;
            nnz_total_q      <= nnz_total_d;
            global_nnz_ptr_q <= global_nnz_ptr_d;
            col_id_q         <= col_id_d;
        end
    end

    always_comb begin
        next_state          = current_state;
        row_idx_d           = row_idx_q;
        nnz_count_d         = nnz_count_q;
        nnz_total_d         = nnz_total_q;
        global_nnz_ptr_d    = global_nnz_ptr_q;
        col_id_d            = col_id_q;

        busy_o              = 1'b1;
        done_o              = 1'b0;

        row_ptr_read_addr_o = row_idx_q;
        col_id_read_addr_o  = global_nnz_ptr_q + nnz_count_q;
        a_read_addr_o       = global_nnz_ptr_q + nnz_count_q;
        
        b_read_row_addr_o   = REGISTERED_READ ? col_id_q[$clog2(NUM_ROWS)-1:0] : col_id_i[$clog2(NUM_ROWS)-1:0];

        c_write_en_o        = 1'b0;
        c_write_row_addr_o  = row_idx_q;
        
        dp_in_valid_o       = 1'b0;
        dp_out_ready_o      = 1'b0;
        dp_nnz_iterations_o = nnz_total_q;

        case (current_state)

            IDLE: begin
                busy_o = 1'b0;
                if (start_i) begin
                    row_idx_d        = '0;
                    global_nnz_ptr_d = '0;
                    next_state       = FETCH_ROW_PTR;
                end
            end

            FETCH_ROW_PTR: begin
                row_ptr_read_addr_o = row_idx_q;
                next_state          = CALC_NNZ;
            end

            CALC_NNZ: begin
                row_ptr_read_addr_o = row_idx_q;
                nnz_total_d         = row_ptr_end_i - row_ptr_start_i;
                nnz_count_d         = '0;
                
                if (REGISTERED_READ)
                    next_state = WAIT_SCM_ADDR;
                else
                    next_state = PROCESS_NNZ;
            end

            WAIT_SCM_ADDR: begin
                col_id_d   = col_id_i;
                next_state = PROCESS_NNZ;
            end

            PROCESS_NNZ: begin
                dp_in_valid_o = 1'b1;

                if (dp_in_hs) begin
                    if (nnz_total_q == 8'd0) begin
                        next_state = WAIT_DP_OUT;
                    end else begin
                        nnz_count_d = nnz_count_q + 8'd1;
                                               
                        if (nnz_count_q == nnz_total_q - 8'd1) begin
                            global_nnz_ptr_d = global_nnz_ptr_q + nnz_total_q;
                            next_state       = WAIT_DP_OUT;
                        end else begin
                            if (REGISTERED_READ)
                                next_state = WAIT_SCM_ADDR;
                            else
                                next_state = PROCESS_NNZ;
                        end
                    end
                end
            end

            WAIT_DP_OUT: begin
                dp_out_ready_o = 1'b1;
                if (dp_out_valid_i) begin
                    next_state = STORE_C;
                end
            end

            STORE_C: begin
                c_write_en_o       = 1'b1;
                c_write_row_addr_o = row_idx_q;
                next_state         = CHECK_DONE;
            end

            CHECK_DONE: begin
                if (row_idx_q == NUM_ROWS - 1) begin
                    done_o     = 1'b1;
                    busy_o     = 1'b0;
                    next_state = IDLE;
                end else begin
                    row_idx_d  = row_idx_q + 1'b1;
                    next_state = FETCH_ROW_PTR;
                end
            end

            default: next_state = IDLE;

        endcase
    end

endmodule
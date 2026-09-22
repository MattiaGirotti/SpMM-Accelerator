// ============================================================================
// Module: datapath
// Description: HWPE-Stream Compliant Datapath with Correct Row Completion
// ============================================================================

module datapath #(
    parameter int unsigned DATA_WIDTH     = 8,
    parameter int unsigned NUM_MACS       = 4,
    parameter int unsigned NUM_ROWS       = 4,
    parameter int unsigned DATA_WIDTH_OUT = 32
)(
    input  logic                                clk_i,
    input  logic                                rst_ni,
    input  logic                                clear_i,

    // --- Control Signal ---
    input  logic [7:0]                          nnz_iterations_i,
    output logic                                matrix_end_o,

    // --- Input HWPE-Stream Handshake Interface ---
    input  logic                                in_valid_i,
    output logic                                in_ready_o,
    input  wire logic unsigned [DATA_WIDTH-1:0]   data_a_i,
    input  wire logic unsigned [NUM_MACS-1:0][DATA_WIDTH-1:0] data_b_i,

    // --- Output HWPE-Stream Handshake Interface ---
    output logic                                out_valid_o,
    input  logic                                out_ready_i,
    output logic unsigned [NUM_MACS-1:0][DATA_WIDTH_OUT-1:0] data_out_o
);

    // --- Internal Registers & Signals ---
    logic unsigned [NUM_MACS-1:0][DATA_WIDTH_OUT-1:0] mac_acc_out;
    logic [7:0] iteration_count;
    logic [7:0] row_count;
    logic [7:0] current_nnz;

    logic unsigned [DATA_WIDTH-1:0]                data_a_q;
    logic unsigned [NUM_MACS-1:0][DATA_WIDTH-1:0]   data_b_q;

    logic in_hs;
    logic out_hs;
    logic mac_en;
    logic sync_clear;
    logic empty_row;
    logic row_done;

    // --- HWPE Handshake Events ---
    assign in_hs  = in_valid_i && in_ready_o;
    assign out_hs = out_valid_o && out_ready_i;

    assign in_ready_o = !out_valid_o || out_hs;
    assign mac_en     = in_hs && (nnz_iterations_i > 0);

    // --- Sampling Data Input on Handshake ---
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            data_a_q <= '0;
            data_b_q <= '0;
        end else if (clear_i) begin
            data_a_q <= '0;
            data_b_q <= '0;
        end else if (in_hs) begin
            data_a_q <= data_a_i;
            data_b_q <= data_b_i;
        end
    end

    // --- Row Completion Logic ---
    assign sync_clear = (iteration_count == current_nnz) && (current_nnz > 0);
    assign empty_row  = (nnz_iterations_i == 8'd0);
    
    // row_done triggers either when all NNZs are processed or immediately for empty rows
    assign row_done   = sync_clear || (empty_row && in_hs && (iteration_count == 8'd0));

    // Sample current_nnz on row start/advance
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            current_nnz <= 8'd0;
        end else if (clear_i) begin
            current_nnz <= 8'd0;
        end else if (out_hs || (iteration_count == 8'd0 && in_hs)) begin
            current_nnz <= nnz_iterations_i;
        end
    end

    // --- Iteration Counter Logic ---
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            iteration_count <= 8'd0;
        end else if (clear_i) begin
            iteration_count <= 8'd0;
        end else if (out_hs) begin
            iteration_count <= 8'd0;
        end else if (in_hs) begin
            iteration_count <= iteration_count + 8'd1;
        end
    end

    // --- Row Counter Logic ---
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            row_count <= 8'd0;
        end else if (clear_i) begin
            row_count <= 8'd0;
        end else if (out_hs) begin
            if (row_count == NUM_ROWS - 1) begin
                row_count <= 8'd0;
            end else begin
                row_count <= row_count + 8'd1;
            end
        end
    end

    // --- MAC Module Instances ---
    genvar i;
    generate
        for (i = 0; i < NUM_MACS; i++) begin : mac_instances
            mac_int8 u_mac (
                .clk   (clk_i),
                .rst_n (rst_ni),
                .clr   (clear_i || out_hs),
                .en    (in_hs),
                .a     (data_a_i),
                .b     (data_b_i[i]),
                .acc   (mac_acc_out[i])
            );
        end
    endgenerate

    // --- Output Interface Handshake Logic ---
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            data_out_o   <= '0;
            matrix_end_o <= 1'b0;
            out_valid_o  <= 1'b0;
        end else if (clear_i) begin
            data_out_o   <= '0;
            matrix_end_o <= 1'b0;
            out_valid_o  <= 1'b0; 
        end else begin
            if (out_hs) begin
                out_valid_o <= 1'b0;
            end else if (row_done) begin
                out_valid_o  <= 1'b1;
                matrix_end_o <= (row_count == NUM_ROWS - 1);
                data_out_o   <= empty_row ? '0 : mac_acc_out;
            end
        end
    end

endmodule
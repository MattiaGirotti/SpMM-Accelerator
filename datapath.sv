// ============================================================================
// Module: datapath
// Description: HWPE-Stream Compliant Datapath with Valid/Ready Handshakes & Clear
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
    input  logic [15:0]                         nnz_iterations_i,
    output logic                                matrix_end_o,

    // --- Input HWPE-Stream Handshake Interface ---
    input  logic                                in_valid_i,
    output logic                                in_ready_o,
    input  logic unsigned [DATA_WIDTH-1:0]        data_a_i,
    input  logic unsigned [NUM_MACS-1:0][DATA_WIDTH-1:0] data_b_i,

    // --- Output HWPE-Stream Handshake Interface ---
    output logic                                out_valid_o,
    input  logic                                out_ready_i,
    output logic unsigned [NUM_MACS-1:0][DATA_WIDTH_OUT-1:0] data_out_o
);

    // --- Internal Registers & Signals ---
    logic unsigned [NUM_MACS-1:0][DATA_WIDTH_OUT-1:0] mac_acc_out;
    logic [15:0] iteration_count;
    logic [15:0] row_count;
    logic [15:0] current_nnz;

    logic in_hs;
    logic out_hs;
    logic mac_en;
    logic sync_clear;
    logic empty_row;
    logic row_advance;

    // --- HWPE Handshake Events ---
    // Atomic handshake event on input channel
    assign in_hs  = in_valid_i && in_ready_o;
    // Atomic handshake event on output channel
    assign out_hs = out_valid_o && out_ready_i;

    // Ready to accept new input only when output buffer/register is not holding unconsumed data
    assign in_ready_o = !out_valid_o || out_hs;

    // MAC computation enable occurs only on valid input handshake (when non-zero iterations exist)
    assign mac_en = in_hs && (current_nnz > 0);

    // --- Sampling & Row Advance Logic ---
    assign sync_clear  = (iteration_count == current_nnz) && (current_nnz > 0);
    assign empty_row   = (nnz_iterations_i == 16'd0) && (iteration_count == 16'd0);
    assign row_advance = (sync_clear || empty_row) && in_hs;

    // Sample current_nnz on row advance or initial cycle
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            current_nnz <= 16'd0;
        end else if (clear_i) begin
            current_nnz <= 16'd0;
        end else if (in_hs) begin
            if (row_advance || iteration_count == 16'd0) begin
                current_nnz <= nnz_iterations_i;
            end
        end
    end

    // --- Iteration Counter Logic ---
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            iteration_count <= 16'd0;
        end else if (clear_i) begin
            iteration_count <= 16'd0;
        end else if (in_hs) begin
            if (row_advance) begin
                iteration_count <= (nnz_iterations_i > 0) ? 16'd1 : 16'd0;
            end else begin
                iteration_count <= iteration_count + 16'd1;
            end
        end
    end

    // --- Row Counter Logic ---
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            row_count <= 16'd0;
        end else if (clear_i) begin
            row_count <= 16'd0;
        end else if (row_advance) begin
            if (row_count == NUM_ROWS - 1) begin
                row_count <= 16'd0;
            end else begin
                row_count <= row_count + 16'd1;
            end
        end
    end

    // --- MAC Module Instances ---
    genvar i;
    generate
        for (i = 0; i < NUM_MACS; i++) begin : mac_instances
            mac_int8 #(
                .DATA_WIDTH     (DATA_WIDTH),
                .DATA_WIDTH_OUT (DATA_WIDTH_OUT)
            ) u_mac (
                .clk   (clk_i),
                .rst_n (rst_ni),
                .clr   (clear_i || row_advance),
                .en    (mac_en),
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
            // HWPE Rule 4: Valid can deassert ONLY in the cycle after a valid handshake
            if (out_hs) begin
                out_valid_o <= 1'b0;
            end

            // Assert valid when a row computation finishes
            if (row_advance) begin
                out_valid_o  <= 1'b1;
                matrix_end_o <= (row_count == NUM_ROWS - 1);
                data_out_o   <= empty_row ? '0 : mac_acc_out;
            end
        end
    end

endmodule
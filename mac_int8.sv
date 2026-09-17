// MAC (Multiply-Accumulate) module with synchronous reset
module mac_int8 (
    input  logic               clk,
    input  logic               rst_n,   
    input  logic               clr,     // Synchronous clear signal
    input  logic               en,      
    input  logic signed [7:0]  a,       
    input  logic signed [7:0]  b,       
    output logic signed [31:0] acc      
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= 32'd0;
        end else if (clr) begin
            // If clear is asserted but input data is already valid for the next row,
            // start the new accumulation directly instead of wasting a clock cycle.
            if (en) acc <= (a * b);
            else    acc <= 32'd0;
        end else if (en) begin
            acc <= acc + (a * b);
        end
    end

endmodule
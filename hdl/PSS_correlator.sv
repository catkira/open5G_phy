`timescale 1ns / 1ns

module PSS_correlator
#(
    parameter IN_DW = 32,          // input data width
    parameter OUT_DW = 16          // input data width
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire    signed [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,
    output  reg     signed [OUT_DW-1:0]         m_axis_out_tdata,
    output  reg                                 m_axis_out_tvalid
);

always_ff @(posedge clk_i) begin
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
    end
end

endmodule
`timescale 1ns / 1ns

module PSS_correlator
#(
    parameter IN_DW = 32,          // input data width
    parameter OUT_DW = 16,         // output data width
    parameter PSS_LEN = 127,
    parameter [32*(PSS_LEN)-1:0] PSS_LOCAL = {(PSS_LEN){32'd0}}
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire    signed [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,
    output  reg     [OUT_DW-1:0]                m_axis_out_tdata,
    output  reg                                 m_axis_out_tvalid
);

initial begin
    for (integer i=0; i<10; i=i+1) begin
        $display("PSS_LOCAL[%d] = %d + j%d", i, PSS_LOCAL[i*32+:16], PSS_LOCAL[i*32+16+:16]);
    end
end

reg signed [IN_DW-1:0] in_ff [0:127];
reg signed [IN_DW-1:0] multiplied [0:127];
reg valid;

always @(posedge clk_i) begin // cannot use $display inside always_ff
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
        m_axis_out_tvalid <= '0;
        valid <= '0;
        for (integer i=0; i<PSS_LEN; i++) begin
            in_ff[i] <= '0;
        end        
    end
    else begin
        if (s_axis_in_tvalid) begin
            in_ff[0] <= s_axis_in_tdata;
            for (integer i=0; i<PSS_LEN; i++) begin
                in_ff[i+1] <= in_ff[i];
            end
            // $display("in_ff[0] = %d + j%d", in_ff[0][IN_DW/2:0], in_ff[0][IN_DW-1-:IN_DW/2]);
            valid <= 1'b1;
        end else begin
            valid <= '0;
        end

        m_axis_out_tvalid <= valid;
        if (valid) begin
            m_axis_out_tdata <= sum_im*sum_im + sum_re*sum_re;
        end else begin
            m_axis_out_tdata <= '0;
        end
    end
end

reg signed [15:0] sum_im, sum_re;
always_comb begin
    sum_im = 16'd0;
    sum_re = 16'd0;
    for (integer i=0; i<PSS_LEN; i++) begin
        sum_im = sum_im + in_ff[i][IN_DW/2-1:0] * PSS_LOCAL[i*32+16+:16];
        sum_re = sum_re + in_ff[i][IN_DW-1-:IN_DW/2] * PSS_LOCAL[i*32+:16];
    end
end

`ifdef COCOTB_SIM
initial begin
  $dumpfile ("PSS_correlator.vcd");
  $dumpvars (0, PSS_correlator);
  #1;
end
`endif

endmodule
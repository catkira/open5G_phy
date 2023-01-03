`timescale 1ns / 1ns

module PSS_correlator
#(
    parameter IN_DW = 32,          // input data width
    parameter OUT_DW = 32,         // output data width
    parameter PSS_LEN = 127,
    /* verilator lint_off WIDTH */
    parameter [32*(PSS_LEN)-1:0] PSS_LOCAL = {PSS_LEN{32'b0}}
    /* verilator lint_on WIDTH */
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire    signed [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,
    output  reg            [OUT_DW-1:0]         m_axis_out_tdata,
    output  reg                                 m_axis_out_tvalid
);

localparam REQUIRED_OUT_DW = IN_DW + 3 + 2*$clog2(PSS_LEN);
localparam POSSIBLE_IN_DW = OUT_DW - $clog2(PSS_LEN)*2 - 3;
localparam POSSIBLE_OP_DW = POSSIBLE_IN_DW/2;

wire signed [POSSIBLE_OP_DW - 1:0] axis_in_re, axis_in_im;
assign axis_in_re = s_axis_in_tdata[15-:POSSIBLE_OP_DW];
assign axis_in_im = s_axis_in_tdata[31-:POSSIBLE_OP_DW];

reg signed [POSSIBLE_OP_DW-1:0] tap_re, tap_im;

initial begin
    if (REQUIRED_OUT_DW > OUT_DW) begin
        $display("Truncating inputs from %d bits to %d bits to prevent overflows", IN_DW, POSSIBLE_IN_DW);
        $display("OUT_DW should be at least bits %d wide, to prevent truncation!", REQUIRED_OUT_DW);
    end
    // for (integer i=0; i<10; i=i+1) begin
    //     tap_re = PSS_LOCAL[i*IN_DW+IN_DW/2-1-:POSSIBLE_OP_DW];
    //     tap_im = PSS_LOCAL[i*IN_DW+IN_DW-1-:POSSIBLE_OP_DW];
    //     $display("PSS_LOCAL[%d] = %d + j%d", i, tap_re, tap_im);
    // end
end

reg signed [POSSIBLE_OP_DW-1:0] in_re [0:PSS_LEN-1];
reg signed [POSSIBLE_OP_DW-1:0] in_im [0:PSS_LEN-1];
reg valid;

always @(posedge clk_i) begin // cannot use $display inside always_ff with iverilog
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
        m_axis_out_tvalid <= '0;
        valid <= '0;
        for (integer i=0; i<PSS_LEN; i++) begin
            in_re[i] <= '0;
            in_im[i] <= '0;
        end        
    end
    else begin
        if (s_axis_in_tvalid) begin
            in_re[0] <= axis_in_re;
            in_im[0] <= axis_in_im;
            for (integer i=0; i<PSS_LEN; i++) begin
                in_re[i+1] <= in_re[i];
                in_im[i+1] <= in_im[i];
            end
            valid <= 1'b1;
        end else begin
            valid <= '0;
        end

        if (valid) begin
            m_axis_out_tdata <= sum_im*sum_im + sum_re*sum_re;
            m_axis_out_tvalid <= '1;
        end else begin
            m_axis_out_tdata <= '0;
            m_axis_out_tvalid <= '0;
        end
    end
end

reg signed [OUT_DW-1:0] sum_im, sum_re;
always_comb begin
    sum_im = '0;
    sum_re = '0;
    for (integer i=0; i<PSS_LEN; i++) begin
        tap_re = PSS_LOCAL[i*IN_DW+IN_DW/2-1-:POSSIBLE_IN_DW/2];
        tap_im = PSS_LOCAL[i*IN_DW+IN_DW-1-:POSSIBLE_IN_DW/2];        
        sum_im = sum_im + in_re[i] * tap_im + in_im[i] * tap_re;
        sum_re = sum_re + in_re[i] * tap_re - in_im[i] * tap_im;
    end
end

`ifdef COCOTB_SIM
initial begin
  $dumpfile ("PSS_correlator.vcd");
  $dumpvars (0, PSS_correlator);
  // #1;
end
`endif

endmodule
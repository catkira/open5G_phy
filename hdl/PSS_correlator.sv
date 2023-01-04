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

localparam TAP_DW = 32;
localparam POSSIBLE_IN_DW = OUT_DW 
                            - ($clog2(PSS_LEN)+1)*2  // $clog2(PSS_LEN)*2 additions
                            - 1                      // one 1 addition when calculating abs();
                            - 2;                     // for signed -> unsigned conversion
localparam POSSIBLE_OP_DW = POSSIBLE_IN_DW/2;
localparam REQUIRED_OUT_DW = IN_DW + POSSIBLE_IN_DW - OUT_DW;

wire signed [POSSIBLE_OP_DW - 1:0] axis_in_re, axis_in_im;
assign axis_in_re = s_axis_in_tdata[15-:POSSIBLE_OP_DW];
assign axis_in_im = s_axis_in_tdata[31-:POSSIBLE_OP_DW];

reg signed [POSSIBLE_OP_DW-1:0] tap_re, tap_im;

initial begin
    if (REQUIRED_OUT_DW > OUT_DW) begin
        $display("Truncating inputs from %d bits to %d bits to prevent overflows", IN_DW, POSSIBLE_IN_DW);
        $display("OUT_DW should be at least bits %d wide, to prevent truncation!", REQUIRED_OUT_DW);
    end
    for (integer i=0; i<10; i=i+1) begin
        tap_re = PSS_LOCAL[i*TAP_DW+TAP_DW/2-1-:POSSIBLE_OP_DW];
        tap_im = PSS_LOCAL[i*TAP_DW+TAP_DW-1-:POSSIBLE_OP_DW];
        $display("PSS_LOCAL[%d] = %d + j%d", i, tap_re, tap_im);
        tap_re = PSS_LOCAL[(PSS_LEN-i-1)*TAP_DW+TAP_DW/2-1-:POSSIBLE_OP_DW];
        tap_im = PSS_LOCAL[(PSS_LEN-i-1)*TAP_DW+TAP_DW-1-:POSSIBLE_OP_DW];
        $display("PSS_LOCAL[%d] = %d + j%d", PSS_LEN-i-1, tap_re, tap_im);
    end
end

reg signed [POSSIBLE_OP_DW - 1 : 0] in_re [0 : PSS_LEN - 1];
reg signed [POSSIBLE_OP_DW - 1 : 0] in_im [0 : PSS_LEN - 1];
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
    if (0) begin
        // 4*PSS_LEN multiplications
        for (integer i=0; i<PSS_LEN; i++) begin            
            tap_re = PSS_LOCAL[i*TAP_DW+TAP_DW/2-1-:POSSIBLE_OP_DW];
            tap_im = PSS_LOCAL[i*TAP_DW+TAP_DW-1-:POSSIBLE_OP_DW];      
            sum_im = sum_im + in_re[i] * tap_im + in_im[i] * tap_re;
            sum_re = sum_re + in_re[i] * tap_re - in_im[i] * tap_im;
        end
    end else begin
        // 2*PSS_LEN multiplications
        // simplification by taking into account that PSS is 
        // complex conjugate centrally symetric in time-domain
        
        // first tap has no symmetric pair, so it has to be calculated as before
        tap_re = PSS_LOCAL[TAP_DW / 2 - 1 -: TAP_DW / 2];
        tap_im = -PSS_LOCAL[TAP_DW - 1 -: TAP_DW / 2];      
        sum_im = sum_im + in_re[0] * tap_im + in_im[0] * tap_re;
        sum_re = sum_re + in_re[0] * tap_re - in_im[0] * tap_im;
        for (integer i = 1; i < PSS_LEN / 2; i++) begin
            tap_re = PSS_LOCAL[i * TAP_DW + TAP_DW / 2 - 1 -: POSSIBLE_OP_DW];
            tap_im = -PSS_LOCAL[i * TAP_DW + TAP_DW - 1 -: POSSIBLE_OP_DW];      
            sum_re = sum_re + (in_re[i] + in_re[PSS_LEN - i]) * tap_re
                            + (in_im[i] - in_im[PSS_LEN - i]) * tap_im;
            sum_im = sum_im + (in_im[i] + in_im[PSS_LEN - i]) * tap_re
                            - (in_re[i] + in_re[PSS_LEN - i]) * tap_im;
        end
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
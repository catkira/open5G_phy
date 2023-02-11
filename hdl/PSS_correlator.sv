// It's best to not use truncation inside this module, because 
// truncation is only implemented rudimentally without rounding

`timescale 1ns / 1ns

module PSS_correlator
#(
    parameter IN_DW = 32,          // input data width
    parameter OUT_DW = 24,         // output data width
    parameter TAP_DW = 32,
    parameter PSS_LEN = 128,
    parameter [TAP_DW * PSS_LEN - 1 : 0] PSS_LOCAL = {(PSS_LEN * TAP_DW){1'b0}},
    parameter ALGO = 1
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire           [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,
    output  reg            [OUT_DW-1:0]         m_axis_out_tdata,
    output  reg                                 m_axis_out_tvalid
);

localparam REQUIRED_OUT_DW = IN_DW + TAP_DW + 2 + 2 * $clog2(PSS_LEN);

localparam IN_OP_DW  = IN_DW / 2;
localparam TAP_OP_DW = TAP_DW / 2;

wire signed [IN_OP_DW - 1 : 0] axis_in_re, axis_in_im;
assign axis_in_re = s_axis_in_tdata[IN_DW / 2 - 1 -: IN_OP_DW];
assign axis_in_im = s_axis_in_tdata[IN_DW - 1     -: IN_OP_DW];

reg signed [TAP_OP_DW - 1 : 0] tap_re, tap_im;

reg signed [IN_OP_DW - 1 : 0] in_re [0 : PSS_LEN - 1];
reg signed [IN_OP_DW - 1 : 0] in_im [0 : PSS_LEN - 1];
reg valid;
reg signed [REQUIRED_OUT_DW / 2 : 0] sum_im, sum_re;

initial begin
    for (integer i = 0; i < PSS_LEN; i = i + 1) begin
        // tap_re = PSS_LOCAL[i * TAP_DW + TAP_DW / 2 - 1 -: TAP_OP_DW];
        // tap_im = PSS_LOCAL[i * TAP_DW + TAP_DW     - 1 -: TAP_OP_DW];
        // $display("PSS_LOCAL[%d] = %d + j%d", i, tap_re, tap_im);
        // tap_re = PSS_LOCAL[(PSS_LEN-i-1)*TAP_DW+TAP_DW/2-1-:TAP_OP_DW];
        // tap_im = PSS_LOCAL[(PSS_LEN-i-1)*TAP_DW+TAP_DW-1-:TAP_OP_DW];
        // $display("PSS_LOCAL[%d] = %d + j%d", PSS_LEN-i-1, tap_re, tap_im);
    end
end

reg [REQUIRED_OUT_DW - 1: 0] filter_result;
// assign filter_result = sum_im * sum_im + sum_re * sum_re;

function [REQUIRED_OUT_DW / 2 : 0] abs;
    input signed [REQUIRED_OUT_DW / 2 : 0] arg;
begin
    abs = arg[REQUIRED_OUT_DW / 2] ? ~arg + 1 : arg;
end
endfunction

always @(posedge clk_i) begin // cannot use $display inside always_ff with iverilog
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
        m_axis_out_tvalid <= '0;
        valid <= '0;
        for (integer i = 0; i < PSS_LEN; i++) begin
            in_re[i] <= '0;
            in_im[i] <= '0;
        end        
    end
    else begin
        if (s_axis_in_tvalid) begin
            in_re[0] <= axis_in_re;
            in_im[0] <= axis_in_im;
            for (integer i = 0; i < (PSS_LEN - 1); i++) begin
                in_re[i + 1] <= in_re[i];
                in_im[i + 1] <= in_im[i];
            end
            valid <= 1'b1;
        end else begin
            valid <= '0;
        end

        if (valid) begin
            sum_im = '0;
            sum_re = '0;
            if (ALGO == 0) begin
                // 4*PSS_LEN multiplications
                for (integer i = 0; i < PSS_LEN; i++) begin            
                    tap_re = PSS_LOCAL[i * TAP_DW + TAP_DW / 2 - 1 -: TAP_OP_DW];
                    tap_im = PSS_LOCAL[i * TAP_DW + TAP_DW     - 1 -: TAP_OP_DW];      
                    sum_re = sum_re + in_re[i] * tap_re - in_im[i] * tap_im;
                    sum_im = sum_im + in_re[i] * tap_im + in_im[i] * tap_re;
                end
            end else begin
                // 2*PSS_LEN multiplications
                // simplification by taking into account that PSS is 
                // complex conjugate centrally symetric in time-domain
                
                integer i = 0;
                if (0) begin
                    // tap[0] and tap[64] symmetric pair, so it has to be calculated as before
                    // another source for error is that the taps are not perfectly symmetric,
                    // when truncation is used, because rounding is not implemented in that case
                    // these 2 taps can also be discarded for simplicity
                    tap_re =  PSS_LOCAL[i * TAP_DW + TAP_DW / 2 - 1 -: TAP_OP_DW];
                    tap_im =  PSS_LOCAL[i * TAP_DW + TAP_DW     - 1 -: TAP_OP_DW];      
                    sum_re = sum_re + in_re[i] * tap_re - in_im[i] * tap_im;
                    sum_im = sum_im + in_re[i] * tap_im + in_im[i] * tap_re;
                    i = 64;
                    tap_re =  PSS_LOCAL[i * TAP_DW + TAP_DW / 2 - 1 -: TAP_OP_DW];
                    tap_im =  PSS_LOCAL[i * TAP_DW + TAP_DW     - 1 -: TAP_OP_DW];      
                    sum_re = sum_re + in_re[i] * tap_re - in_im[i] * tap_im;
                    sum_im = sum_im + in_re[i] * tap_im + in_im[i] * tap_re;
                end

                for (i = 1; i < PSS_LEN / 2; i++) begin
                    tap_re = PSS_LOCAL[i * TAP_DW + TAP_DW / 2 - 1 -: TAP_OP_DW];
                    tap_im = PSS_LOCAL[i * TAP_DW + TAP_DW     - 1 -: TAP_OP_DW];
                    sum_re = sum_re + (in_re[PSS_LEN - i] + in_re[i]) * tap_re
                                    + (in_im[PSS_LEN - i] - in_im[i]) * tap_im;
                    sum_im = sum_im + (in_im[PSS_LEN - i] + in_im[i]) * tap_re
                                    - (in_re[PSS_LEN - i] - in_re[i]) * tap_im;
                end
            end

            // https://openofdm.readthedocs.io/en/latest/verilog.html
            if (abs(sum_im) > abs(sum_re))   filter_result = abs(sum_im) + (abs(sum_re) >> 2);
            else                             filter_result = abs(sum_re) + (abs(sum_im) >> 2);

            if (REQUIRED_OUT_DW >= OUT_DW) begin
                m_axis_out_tdata <= filter_result[REQUIRED_OUT_DW - 1 -: OUT_DW];
            end else begin
                // do zero padding
                m_axis_out_tdata <= {{(OUT_DW - REQUIRED_OUT_DW){1'b0}}, filter_result};
            end
            m_axis_out_tvalid <= '1;
        end else begin
            m_axis_out_tdata <= '0;
            m_axis_out_tvalid <= '0;
        end
    end
end

endmodule
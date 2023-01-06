// It's best to not use truncation inside this module, because 
// truncation is only implemented rudimentally without rounding

`timescale 1ns / 1ns

module PSS_correlator
#(
    parameter IN_DW = 32,          // input data width
    parameter OUT_DW = 32,         // output data width
    parameter PSS_LEN = 127,
    parameter [32 * PSS_LEN - 1 : 0] PSS_LOCAL = {PSS_LEN{32'b0}}
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire           [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,
    output  reg            [OUT_DW-1:0]         m_axis_out_tdata,
    output  reg                                 m_axis_out_tvalid
);

localparam TAP_DW = 32;
localparam POSSIBLE_IN_DW = OUT_DW 
                            - ($clog2(PSS_LEN) + 1) * 2  // $clog2(PSS_LEN)*2 bits for additions
                            - 1                          // 1 bit for addition when calculating abs();
                            - 2;                         // 2 bits for conversions from signed -> unsigned
localparam REQUIRED_OUT_DW = IN_DW - POSSIBLE_IN_DW + OUT_DW;
localparam TRUNCATE = POSSIBLE_IN_DW < IN_DW;

localparam IN_OP_DW  = TRUNCATE ? POSSIBLE_IN_DW / 2 : IN_DW / 2;                        // truncated data width of input signal
localparam TAP_OP_DW = TRUNCATE ? POSSIBLE_IN_DW / 2 + POSSIBLE_IN_DW % 2 : TAP_DW / 2;  // truncated data width of filter taps
// give TAP_OP_DW one more digit that IN_OP_DW if POSSIBLE_IN_DW is an odd number

wire signed [IN_OP_DW - 1 : 0] axis_in_re, axis_in_im;
assign axis_in_re = s_axis_in_tdata[15 -: IN_OP_DW];
assign axis_in_im = s_axis_in_tdata[31 -: IN_OP_DW];

reg signed [TAP_OP_DW - 1 : 0] tap_re, tap_im;

reg signed [IN_OP_DW - 1 : 0] in_re [0 : PSS_LEN - 1];
reg signed [IN_OP_DW - 1 : 0] in_im [0 : PSS_LEN - 1];
reg valid;
reg signed [OUT_DW : 0] sum_im, sum_re;

initial begin
    if (TRUNCATE) begin
        $display("IN_DW = %d, OUT_DW = %d, IN_OP_DW = %d", IN_DW, OUT_DW, IN_OP_DW);
        $display("Truncating inputs from %d bits to %d bits to prevent overflows", IN_DW, POSSIBLE_IN_DW);
        $display("OUT_DW should be at least bits %d wide, to prevent truncation!", REQUIRED_OUT_DW);
    end
    for (integer i = 0; i < 128; i = i + 1) begin
        // tap_re = PSS_LOCAL[i*TAP_DW+TAP_DW/2-1-:IN_OP_DW];
        // tap_im = PSS_LOCAL[i*TAP_DW+TAP_DW-1-:IN_OP_DW];
        // $display("PSS_LOCAL[%d] = %d + j%d", i, tap_re, tap_im);
        // tap_re = PSS_LOCAL[(PSS_LEN-i-1)*TAP_DW+TAP_DW/2-1-:IN_OP_DW];
        // tap_im = PSS_LOCAL[(PSS_LEN-i-1)*TAP_DW+TAP_DW-1-:IN_OP_DW];
        // $display("PSS_LOCAL[%d] = %d + j%d", PSS_LEN-i-1, tap_re, tap_im);
    end
end

wire signed [OUT_DW:0] filter_result; // OUT_DW +1 bits
assign filter_result = sum_im * sum_im + sum_re * sum_re;

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
            in_re[PSS_LEN-1] <= axis_in_re;
            in_im[PSS_LEN-1] <= axis_in_im;
            for (integer i = 0; i < (PSS_LEN-1); i++) begin
                in_re[PSS_LEN - 2 - i] <= in_re[PSS_LEN - 1 - i];
                in_im[PSS_LEN - 2 - i] <= in_im[PSS_LEN - 1 - i];
            end
            valid <= 1'b1;
        end else begin
            valid <= '0;
        end

        if (valid) begin
            sum_im = '0;
            sum_re = '0;
            if (0) begin
                // 4*PSS_LEN multiplications
                for (integer i = 0; i < PSS_LEN; i++) begin            
                    tap_re =  PSS_LOCAL[i * TAP_DW + TAP_DW / 2 - 1 -: TAP_OP_DW];
                    tap_im = -PSS_LOCAL[i * TAP_DW + TAP_DW     - 1 -: TAP_OP_DW];      
                    sum_re = sum_re + in_re[i] * tap_re - in_im[i] * tap_im;
                    sum_im = sum_im + in_re[i] * tap_im + in_im[i] * tap_re;
                end
            end else begin
                // 2*PSS_LEN multiplications
                // simplification by taking into account that PSS is 
                // complex conjugate centrally symetric in time-domain
                
                // first tap has no symmetric pair, so it has to be calculated as before
                tap_re = PSS_LOCAL[TAP_DW / 2 - 1 -: TAP_OP_DW];
                tap_im = PSS_LOCAL[TAP_DW     - 1 -: TAP_OP_DW];
                sum_im = sum_im + in_re[0] * tap_im + in_im[0] * tap_re;
                sum_re = sum_re + in_re[0] * tap_re - in_im[0] * tap_im;
                for (integer i = 1; i < PSS_LEN / 2; i++) begin
                    tap_re = PSS_LOCAL[i * TAP_DW + TAP_DW / 2 - 1 -: TAP_OP_DW];
                    tap_im = PSS_LOCAL[i * TAP_DW + TAP_DW     - 1 -: TAP_OP_DW];
                    sum_re = sum_re + (in_re[i] + in_re[PSS_LEN - i]) * tap_re
                                    + (in_im[i] - in_im[PSS_LEN - i]) * tap_im;
                    sum_im = sum_im + (in_im[i] + in_im[PSS_LEN - i]) * tap_re
                                    - (in_re[i] - in_re[PSS_LEN - i]) * tap_im;
                end
            end            
            m_axis_out_tdata <= filter_result[OUT_DW - 1 : 0];   //  cast from signed to unsigned
            m_axis_out_tvalid <= '1;
        end else begin
            m_axis_out_tdata <= '0;
            m_axis_out_tvalid <= '0;
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
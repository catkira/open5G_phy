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
    parameter ALGO = 1,
    parameter USE_TAP_FILE = 0,
    parameter TAP_FILE = "",
    parameter TAP_FILE_PATH = "",
    parameter N_ID_2 = 0,
    localparam C_DW = IN_DW + TAP_DW + 2 + 2 * $clog2(PSS_LEN)
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire           [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,
    input                                       enable_i,
    output  reg            [OUT_DW-1:0]         m_axis_out_tdata,
    output  reg                                 m_axis_out_tvalid,
    output  reg            [C_DW - 1 : 0]       C0_o,
    output  reg            [C_DW - 1 : 0]       C1_o,

    // debug outputs
    output                 [TAP_DW - 1 : 0]     taps_o [0 : PSS_LEN - 1]
);

localparam IN_OP_DW  = IN_DW / 2;
localparam TAP_OP_DW = TAP_DW / 2;
localparam REQUIRED_OUT_DW = IN_OP_DW + TAP_OP_DW + 1 + $clog2(PSS_LEN);

reg signed [REQUIRED_OUT_DW - 1 : 0] C0_im, C0_re; // partial sums, used for CFO estimation

wire signed [IN_OP_DW - 1 : 0] axis_in_re, axis_in_im;
assign axis_in_re = s_axis_in_tdata[IN_DW / 2 - 1 -: IN_OP_DW];
assign axis_in_im = s_axis_in_tdata[IN_DW - 1     -: IN_OP_DW];

reg signed [TAP_OP_DW - 1 : 0] tap_re, tap_im;

reg signed [IN_OP_DW - 1 : 0] in_re [0 : PSS_LEN - 1];
reg signed [IN_OP_DW - 1 : 0] in_im [0 : PSS_LEN - 1];
reg valid;
reg signed [REQUIRED_OUT_DW - 1 : 0] sum_im, sum_re;

reg [TAP_DW - 1 : 0] taps [0 : PSS_LEN - 1];
assign taps_o = taps;
initial begin
    if (USE_TAP_FILE) begin
        if (TAP_FILE == "") begin
            if (TAP_FILE_PATH == "") begin
                $display("load PSS_correlator taps from %s", $sformatf("PSS_taps_%0d.hex", N_ID_2));
                $readmemh($sformatf("PSS_taps_%0d.hex", N_ID_2), taps);
            end else begin
                $display("load PSS_correlator taps from %s", $sformatf("%s/PSS_taps_%0d.hex", TAP_FILE_PATH, N_ID_2));
                $readmemh($sformatf("%s/PSS_taps_%0d.hex", TAP_FILE_PATH, N_ID_2), taps);
            end
        end else begin
            $display("load PSS_correlator taps from %s", TAP_FILE);
            $readmemh(TAP_FILE, taps);
        end
    end else begin
        $display("loading PSS_correlator taps from PSS_LOCAL parameter");
    end
    // for (integer i = 0; i < PSS_LEN; i = i + 1) begin
    //     if (N_ID_2 == 2) begin
    //         tap_im = get_tap_im(i);
    //         tap_re = get_tap_re(i);
    //         $display("PSS_LOCAL[%d] = %d + j%d", i, tap_re, tap_im);
    //     end
    //     // tap_re = PSS_LOCAL[i * TAP_DW + TAP_DW / 2 - 1 -: TAP_OP_DW];
    //     // tap_im = PSS_LOCAL[i * TAP_DW + TAP_DW     - 1 -: TAP_OP_DW];
    //     // $display("PSS_LOCAL[%d] = %d + j%d", i, tap_re, tap_im);
    //     // tap_re = PSS_LOCAL[(PSS_LEN-i-1)*TAP_DW+TAP_DW/2-1-:TAP_OP_DW];
    //     // tap_im = PSS_LOCAL[(PSS_LEN-i-1)*TAP_DW+TAP_DW-1-:TAP_OP_DW];
    //     // $display("PSS_LOCAL[%d] = %d + j%d", PSS_LEN-i-1, tap_re, tap_im);
    // end
end

function [TAP_OP_DW - 1 : 0] get_tap_im;
    input integer arg;
begin
    if (USE_TAP_FILE)  get_tap_im = taps[arg] >> TAP_OP_DW;
    else               get_tap_im = PSS_LOCAL[arg * TAP_DW + TAP_DW - 1 -: TAP_OP_DW];
end
endfunction

function [TAP_OP_DW - 1 : 0] get_tap_re;
    input integer arg;
begin
    if (USE_TAP_FILE)  get_tap_re = taps[arg][TAP_OP_DW - 1 : 0];
    else               get_tap_re = PSS_LOCAL[arg * TAP_DW + TAP_DW / 2 - 1 -: TAP_OP_DW];
end
endfunction


reg [REQUIRED_OUT_DW - 1: 0] filter_result;
// assign filter_result = sum_im * sum_im + sum_re * sum_re;

function [REQUIRED_OUT_DW - 1 : 0] abs;
    input signed [REQUIRED_OUT_DW - 1 : 0] arg;
begin
    abs = arg[REQUIRED_OUT_DW - 1] ? ~arg + 1 : arg;
end
endfunction

localparam OUTPUT_PAD_BITS = REQUIRED_OUT_DW >= OUT_DW ? 0 : OUT_DW - REQUIRED_OUT_DW;

genvar ii;
for (ii = 0; ii < PSS_LEN; ii++) begin
    always @(posedge clk_i) begin
        if (!reset_ni) begin
            in_re[ii] <= '0;
            in_im[ii] <= '0;
        end else if (s_axis_in_tvalid) begin
            if (ii == 0) begin
                in_re[0] <= axis_in_re;
                in_im[0] <= axis_in_im;
            end
            if (ii < PSS_LEN - 1) begin
                in_re[ii + 1] <= in_re[ii];
                in_im[ii + 1] <= in_im[ii];
            end
        end
    end
end


always @(posedge clk_i) begin // cannot use $display inside always_ff with iverilog
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
        m_axis_out_tvalid <= '0;
        valid <= '0;
        C0_im = '0;
        C0_re = '0;
        C0_o <= '0;
        C1_o <= '0;
    end
    else begin
        valid <= s_axis_in_tvalid;
        if (valid) begin
            sum_im = '0;
            sum_re = '0;
            if (ALGO == 0) begin
                // 4*PSS_LEN multiplications
                for (integer i = 0; i < PSS_LEN; i++) begin            
                    tap_re = get_tap_re(i);
                    tap_im = get_tap_im(i);
                    sum_re = sum_re + in_re[i] * tap_re - in_im[i] * tap_im;
                    sum_im = sum_im + in_re[i] * tap_im + in_im[i] * tap_re;
                    if (i == PSS_LEN / 2 - 1) begin
                        C0_im = sum_im;
                        C0_re = sum_re;
                    end
                end
                C0_o <= {C0_im, C0_re};
                C1_o <= {sum_im - C0_im, sum_re - C0_re};
            end else begin
                // 2*PSS_LEN multiplications
                // simplification by taking into account that PSS is 
                // complex conjugate centrally symetric in time-domain
                
                static integer i = 0;
                if (0) begin
                    // tap[0] and tap[64] symmetric pair, so it has to be calculated as before
                    // another source for error is that the taps are not perfectly symmetric,
                    // when truncation is used, because rounding is not implemented in that case
                    // these 2 taps can also be discarded for simplicity
                    tap_re = get_tap_re(i);
                    tap_im = get_tap_im(i);
                    sum_re = sum_re + in_re[i] * tap_re - in_im[i] * tap_im;
                    sum_im = sum_im + in_re[i] * tap_im + in_im[i] * tap_re;
                    i = 64;
                    tap_re = get_tap_re(i);
                    tap_im = get_tap_im(i);
                    sum_re = sum_re + in_re[i] * tap_re - in_im[i] * tap_im;
                    sum_im = sum_im + in_re[i] * tap_im + in_im[i] * tap_re;
                end

                for (i = 1; i < PSS_LEN / 2; i++) begin
                    tap_re = get_tap_re(i);
                    tap_im = get_tap_im(i);
                    sum_re = sum_re + (in_re[PSS_LEN - i] + in_re[i]) * tap_re
                                    + (in_im[PSS_LEN - i] - in_im[i]) * tap_im;
                    sum_im = sum_im + (in_im[PSS_LEN - i] + in_im[i]) * tap_re
                                    - (in_re[PSS_LEN - i] - in_re[i]) * tap_im;
                    if (i == PSS_LEN / 4 - 1) begin
                        C0_im = sum_im;
                        C0_re = sum_re;
                    end
                end
                C0_o <= {C0_im, C0_re};
                C1_o <= {sum_im - C0_im, sum_re - C0_re};
            end

            // https://openofdm.readthedocs.io/en/latest/verilog.html
            if (abs(sum_im) > abs(sum_re))   filter_result = abs(sum_im) + (abs(sum_re) >> 2);
            else                             filter_result = abs(sum_re) + (abs(sum_im) >> 2);

            if (REQUIRED_OUT_DW >= OUT_DW) begin
                m_axis_out_tdata <= enable_i ? filter_result[REQUIRED_OUT_DW - 1 -: OUT_DW] : '0;
            end else begin
                // do zero padding
                // m_axis_out_tdata <= {{(OUT_DW - REQUIRED_OUT_DW){1'b0}}, filter_result};
                m_axis_out_tdata <= enable_i ? {{(OUTPUT_PAD_BITS){1'b0}}, filter_result} : '0;
            end
            m_axis_out_tvalid <= '1;
        end else begin
            m_axis_out_tdata <= '0;
            m_axis_out_tvalid <= '0;
        end
    end
end

endmodule
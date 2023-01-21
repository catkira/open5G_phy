`timescale 1ns / 1ns

module PSS_correlator_mr
#(
    parameter IN_DW = 32,          // input data width
    parameter OUT_DW = 24,         // output data width
    parameter TAP_DW = 32,
    parameter PSS_LEN = 128,
    parameter [TAP_DW * PSS_LEN - 1 : 0] PSS_LOCAL = {(PSS_LEN * TAP_DW){1'b0}},
    parameter ALGO = 1,
    parameter MULT_REUSE = 4
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire           [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,
    output  reg            [OUT_DW-1:0]         m_axis_out_tdata,
    output  reg                                 m_axis_out_tvalid
);

localparam REQUIRED_OUT_DW = IN_DW + TAP_DW + 2 + 2 * $clog2(PSS_LEN) + 1;

localparam IN_OP_DW  = IN_DW / 2;
localparam TAP_OP_DW = TAP_DW / 2;

localparam PSS_LEN_USED = ALGO ? (PSS_LEN - 2) / 2 : PSS_LEN;
localparam REQ_MULTS = (PSS_LEN_USED % MULT_REUSE) != 0 ? PSS_LEN_USED / MULT_REUSE + 1 : PSS_LEN_USED / MULT_REUSE;

wire signed [IN_OP_DW - 1 : 0] axis_in_re, axis_in_im;
assign axis_in_re = s_axis_in_tdata[IN_DW / 2 - 1 -: IN_OP_DW];
assign axis_in_im = s_axis_in_tdata[IN_DW - 1     -: IN_OP_DW];

reg signed [TAP_OP_DW - 1 : 0] tap_re, tap_im;

reg signed [IN_OP_DW - 1 : 0] in_re [0 : PSS_LEN - 1];
reg signed [IN_OP_DW - 1 : 0] in_im [0 : PSS_LEN - 1];
reg valid;
reg signed [REQUIRED_OUT_DW / 2 : 0] sum_im, sum_re;



wire signed [REQUIRED_OUT_DW - 1 : 0] filter_result;
assign filter_result = sum_im * sum_im + sum_re * sum_re;
wire signed [REQUIRED_OUT_DW / 2 : 0] mult_out_re [0 : REQ_MULTS - 1];
wire signed [REQUIRED_OUT_DW / 2 : 0] mult_out_im [0 : REQ_MULTS - 1];

initial begin
    $display("used real multipliers: %d", REQ_MULTS * 4 + 2);
end

for (genvar i_g = 0; i_g < REQ_MULTS; i_g++) begin : mult
    localparam MULT_REUSE_CUR = PSS_LEN_USED - i_g * MULT_REUSE >= MULT_REUSE ? MULT_REUSE : PSS_LEN_USED % MULT_REUSE;
    reg [$clog2(MULT_REUSE) : 0] idx = '0;
    reg signed [REQUIRED_OUT_DW / 2 : 0] out_buf_re, out_buf_im;
    reg [$clog2(PSS_LEN_USED) : 0] pos;
    reg ready;
    assign mult_out_re[i_g] = out_buf_re;
    assign mult_out_im[i_g] = out_buf_im;

    // initial begin
    //     $display("%d MULT_REUSE_CUR = %d",i_g, MULT_REUSE_CUR);
    // end
    always @(posedge clk_i) begin
        if ((!valid && (idx == 0))|| !reset_ni) begin
            idx <= '0;
            out_buf_re <= '0;
            out_buf_im <= '0;
            ready <= '0;
            pos <= ALGO ? i_g * MULT_REUSE + 1 : i_g * MULT_REUSE;
        end else if (idx < MULT_REUSE) begin
            if (valid && (idx != 0)) begin
                $display("Error: valid should not go high now!");
            end
            if (idx < MULT_REUSE_CUR) begin
                tap_re = PSS_LOCAL[pos * TAP_DW + TAP_DW / 2 - 1 -: TAP_OP_DW];
                tap_im = PSS_LOCAL[pos * TAP_DW + TAP_DW     - 1 -: TAP_OP_DW];      
                if (ALGO == 0) begin
                    if (idx == 0) begin
                        out_buf_re <= in_re[pos] * tap_re - in_im[pos] * tap_im;
                        out_buf_im <= in_re[pos] * tap_im + in_im[pos] * tap_re;
                    end else begin
                        out_buf_re <= out_buf_re + in_re[pos] * tap_re - in_im[pos] * tap_im;
                        out_buf_im <= out_buf_im + in_re[pos] * tap_im + in_im[pos] * tap_re;
                    end
                end else begin
                    if (idx == 0) begin
                        out_buf_re <= (in_re[PSS_LEN - pos] + in_re[pos]) * tap_re
                                                + (in_im[PSS_LEN - pos] - in_im[pos]) * tap_im;
                        out_buf_im <= (in_im[PSS_LEN - pos] + in_im[pos]) * tap_re
                                                - (in_re[PSS_LEN - pos] - in_re[pos]) * tap_im;
                    end else begin
                        out_buf_re <= out_buf_re + (in_re[PSS_LEN - pos] + in_re[pos]) * tap_re
                                                + (in_im[PSS_LEN - pos] - in_im[pos]) * tap_im;
                        out_buf_im <= out_buf_im + (in_im[PSS_LEN - pos] + in_im[pos]) * tap_re
                                                - (in_re[PSS_LEN - pos] - in_re[pos]) * tap_im;
                    end
                end
            end
            if (idx == MULT_REUSE - 1) begin
                idx <= '0;
                pos <= ALGO ? i_g * MULT_REUSE + 1 : i_g * MULT_REUSE;
                ready <= '1;
            end else begin
                pos <= pos + 1;
                idx <= idx + 1;
                ready <= '0;
            end
        end
    end
end

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

        if (mult[0].ready) begin
            sum_re = '0;
            sum_im = '0;
            for (integer i = 0; i < REQ_MULTS; i++) begin
                sum_re = sum_re + mult_out_re[i];
                sum_im = sum_im + mult_out_im[i];
            end
            // cast from signed to unsigned, therefore throw away highest bit
            m_axis_out_tdata <= filter_result[REQUIRED_OUT_DW - 2 -: OUT_DW];
            m_axis_out_tvalid <= '1;
        end else begin
            m_axis_out_tdata <= '0;
            m_axis_out_tvalid <= '0;
        end
    end
end

`ifdef COCOTB_SIM
initial begin
  $dumpfile ("PSS_correlator_mr.vcd");
  $dumpvars (0, PSS_correlator_mr);
  // #1;
end
`endif

endmodule
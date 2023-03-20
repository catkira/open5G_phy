`timescale 1ns / 1ns

module PSS_correlator_mr
#(
    parameter IN_DW = 32,          // input data width
    parameter OUT_DW = 24,         // output data width
    parameter TAP_DW = 32,
    parameter PSS_LEN = 128,
    parameter [TAP_DW * PSS_LEN - 1 : 0] PSS_LOCAL = {(PSS_LEN * TAP_DW){1'b0}},
    parameter ALGO = 0,  // not used anymore
    parameter USE_TAP_FILE = 0,
    parameter TAP_FILE = "",
    parameter TAP_FILE_PATH = "",
    parameter N_ID_2 = 0, // not used when PSS_LOCAL is used !
    parameter MULT_REUSE = 4,

    localparam C_DW = IN_DW + TAP_DW + 2 + 2 * $clog2(PSS_LEN)
)
(
    input                                                       clk_i,
    input                                                       reset_ni,
    input   wire           [IN_DW - 1 : 0]                      s_axis_in_tdata,
    input                                                       s_axis_in_tvalid,
    output  reg            [OUT_DW - 1 : 0]                     m_axis_out_tdata,
    output  reg            [C_DW - 1 : 0]                       C0_o,
    output  reg            [C_DW - 1 : 0]                       C1_o,
    output  reg                                                 m_axis_out_tvalid,

    // debug outputs
    output                 [TAP_DW - 1 : 0]                     taps_o [0 : PSS_LEN - 1]    
);

localparam IN_OP_DW  = IN_DW / 2;
localparam TAP_OP_DW = TAP_DW / 2;
localparam REQUIRED_OUT_DW = IN_OP_DW + TAP_OP_DW + 1 + $clog2(PSS_LEN);

localparam PSS_LEN_USED = ALGO ? (PSS_LEN - 2) / 2 : PSS_LEN;
localparam REQ_MULTS = (PSS_LEN_USED % MULT_REUSE) != 0 ? PSS_LEN_USED / MULT_REUSE + 1 : PSS_LEN_USED / MULT_REUSE;

wire signed [IN_OP_DW - 1 : 0] axis_in_re, axis_in_im;
assign axis_in_re = s_axis_in_tdata[IN_DW / 2 - 1 -: IN_OP_DW];
assign axis_in_im = s_axis_in_tdata[IN_DW - 1     -: IN_OP_DW];

reg signed [TAP_OP_DW - 1 : 0] tap_re, tap_im;

reg signed [IN_OP_DW - 1 : 0] in_re [0 : PSS_LEN - 1];
reg signed [IN_OP_DW - 1 : 0] in_im [0 : PSS_LEN - 1];
reg valid;
reg signed [REQUIRED_OUT_DW - 1 : 0] sum_im, sum_re;
reg signed [REQUIRED_OUT_DW - 1 : 0] C0_im, C0_re, C1_im, C1_re; // partial sums, used for CFO estimation
initial begin
    if (REQUIRED_OUT_DW > OUT_DW) $display("truncating output from %d to %d bits", REQUIRED_OUT_DW, OUT_DW);
end


reg unsigned [REQUIRED_OUT_DW - 1: 0] filter_result;
wire signed [REQUIRED_OUT_DW - 1 : 0] mult_out_re [0 : REQ_MULTS - 1];
wire signed [REQUIRED_OUT_DW - 1: 0] mult_out_im [0 : REQ_MULTS - 1];

initial begin
    $display("used real multiplications: %d", REQ_MULTS * 4 + 2);
end

function [REQUIRED_OUT_DW - 1 : 0] abs;
    input signed [REQUIRED_OUT_DW - 1 : 0] arg;
begin
    abs = arg[REQUIRED_OUT_DW - 1] ? ~arg + 1 : arg;
end
endfunction

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

localparam OUTPUT_PAD_BITS = REQUIRED_OUT_DW >= OUT_DW ? 0 : OUT_DW - REQUIRED_OUT_DW;

for (genvar i_g = 0; i_g < REQ_MULTS; i_g++) begin : mult
    localparam MULT_REUSE_CUR = PSS_LEN_USED - i_g * MULT_REUSE >= MULT_REUSE ? MULT_REUSE : PSS_LEN_USED % MULT_REUSE;
    reg [$clog2(MULT_REUSE) : 0] idx = '0;
    reg signed [REQUIRED_OUT_DW - 1: 0] out_buf_re, out_buf_im;
    reg [$clog2(PSS_LEN_USED) : 0] pos;
    reg ready;
    assign mult_out_re[i_g] = out_buf_re;
    assign mult_out_im[i_g] = out_buf_im;
    reg [IN_DW - 1 : 0] mult_in_data;
    reg [TAP_DW - 1 : 0] mult_in_tap;
    reg mult_in_valid;
    wire mult_out_valid;
    localparam MULT_OUT_OP_DW = (IN_DW + TAP_DW) / 2 + 1; // full bit growth
    wire [MULT_OUT_OP_DW * 2 - 1 : 0] mult_out_data;
    wire signed [MULT_OUT_OP_DW - 1 : 0] mult_out_data_im, mult_out_data_re;
    assign mult_out_data_im = mult_out_data[MULT_OUT_OP_DW * 2 - 1 -: MULT_OUT_OP_DW];
    assign mult_out_data_re = mult_out_data[MULT_OUT_OP_DW - 1 : 0];
    complex_multiplier #(
        .OPERAND_WIDTH_A(IN_DW / 2),
        .OPERAND_WIDTH_B(TAP_DW / 2),
        .OPERAND_WIDTH_OUT(MULT_OUT_OP_DW),
        .BYTE_ALIGNED(0),
        .BLOCKING(0)
    )
    complex_multiplier_i(
        .aclk(clk_i),
        .aresetn(reset_ni),
        .s_axis_a_tdata(mult_in_data),
        .s_axis_a_tready(),
        .s_axis_a_tvalid(mult_in_valid),
        .s_axis_b_tdata(mult_in_tap),
        .s_axis_b_tready(),
        .s_axis_b_tvalid(1'b1),

        .m_axis_dout_tready(1'b1),
        .m_axis_dout_tdata(mult_out_data),
        .m_axis_dout_tvalid(mult_out_valid)
    );

    // initial begin
    //     $display("%d MULT_REUSE_CUR = %d",i_g, MULT_REUSE_CUR);
    // end

    // complex_multiplier input process
    always @(posedge clk_i) begin
        if ((!valid && (idx == 0)) || !reset_ni) begin
            idx <= '0;
            mult_in_valid <= '0;
            pos <= ALGO ? i_g * MULT_REUSE + 1 : i_g * MULT_REUSE;
        end else if (idx < MULT_REUSE) begin
            if (valid && (idx != 0)) begin
                $display("Error: valid should not go high now!");
                $finish();
            end
            if (idx < MULT_REUSE_CUR) begin
                tap_re = get_tap_re(pos);
                tap_im = get_tap_im(pos);
                mult_in_data <= {in_im[pos], in_re[pos]};
                mult_in_tap <= {tap_im, tap_re};
                mult_in_valid <= 1;
            end else begin
                mult_in_valid <= '0;
            end

            if (idx == MULT_REUSE - 1) begin
                idx <= '0;
                pos <= ALGO ? i_g * MULT_REUSE + 1 : i_g * MULT_REUSE;
            end else begin
                pos <= pos + 1;
                idx <= idx + 1;
            end
        end
    end

    // complex_multiplier output process
    reg [$clog2(MULT_REUSE) : 0] idx_out;
    always @(posedge clk_i) begin
        if (!reset_ni) begin
            idx_out <= '0;
            out_buf_re <= '0;
            out_buf_im <= '0;
            ready <= '0;
        end else begin
            if (mult_out_valid) begin
                if (idx_out == 0) begin
                    out_buf_re <= mult_out_data_re;
                    out_buf_im <= mult_out_data_im;
                end else begin
                    out_buf_re <= mult_out_data_re + out_buf_re;
                    out_buf_im <= mult_out_data_im + out_buf_im;
                end

                if (idx_out == MULT_REUSE_CUR - 1) begin
                    idx_out <= 0;
                    ready <= '1;
                end else begin
                    idx_out <= idx_out + 1;
                    ready <= 0;
                end
            end else begin
                ready <= 0;
            end
        end
    end
end

// delay line buffer for incoming samples
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

// global output process
always @(posedge clk_i) begin // cannot use $display inside always_ff with iverilog
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
        m_axis_out_tvalid <= '0;
        valid <= '0;
        C0_im = '0;
        C1_im = '0;
        C0_re = '0;
        C1_re = '0;
        C0_o <= '0;
        C1_o <= '0;
    end
    else begin
        valid <= s_axis_in_tvalid;
        if (mult[0].ready) begin
            sum_re = '0;
            sum_im = '0;
            C0_im = '0;
            C0_re = '0;
            C1_im = '0;
            C1_re = '0;
            for (integer i = 0; i < REQ_MULTS; i++) begin
                sum_re = sum_re + mult_out_re[i];
                sum_im = sum_im + mult_out_im[i];
                if (i < (REQ_MULTS / 2)) begin
                    C0_re = C0_re + mult_out_re[i];
                    C0_im = C0_im + mult_out_im[i];
                end else begin
                    C1_re = C1_re + mult_out_re[i];
                    C1_im = C1_im + mult_out_im[i];
                end
            end
            C0_o <= {C0_im, C0_re};
            C1_o <= {C1_im, C1_re};
            
            // https://openofdm.readthedocs.io/en/latest/verilog.html
            if (abs(sum_im) > abs(sum_re))   filter_result = abs(sum_im) + (abs(sum_re) >> 2);
            else                             filter_result = abs(sum_re) + (abs(sum_im) >> 2);

            if (REQUIRED_OUT_DW >= OUT_DW) begin
                m_axis_out_tdata <= filter_result[REQUIRED_OUT_DW - 1 -: OUT_DW];
            end else begin
                // m_axis_out_tdata <= {{(OUT_DW - REQUIRED_OUT_DW){1'b0}}, filter_result};   // do zero padding
                m_axis_out_tdata <= {{(OUTPUT_PAD_BITS){1'b0}}, filter_result};
            end                        
            m_axis_out_tvalid <= '1;
        end else begin
            m_axis_out_tdata <= '0;
            m_axis_out_tvalid <= '0;
        end
    end
end

endmodule
`timescale 1ns / 1ns

module CFO_calc
#(
    parameter C_DW = 32,
    parameter CFO_DW = 20
)
(
    input                                                       clk_i,
    input                                                       reset_ni,
    input           [C_DW - 1 : 0]                              C0_i,
    input           [C_DW - 1 : 0]                              C1_i,
    input                                                       valid_i,

    output  reg     [CFO_DW - 1 : 0]                            CFO_norm_o,
    output  reg                                                 valid_o
);

wire [C_DW - 1 : 0] C1_conj = {-C1_i[C_DW-1 : C_DW/2], C1_i[C_DW/2-1 : 0]};
reg [3 : 0]  state;
reg mult_valid_out;
localparam WAIT_FOR_MULT = 4'b0000;
localparam CALC_DIV      = 4'b0001;
localparam CALC_ATAN     = 4'b0010;
localparam OUTPUT        = 4'b0011;

localparam ATAN_IN_DW = 16;
// LUT out range is 0..pi/4, thereore width can be 3 bits smaller than CFO_DW which has range 0..+-pi
localparam LUT_OUT_DW = CFO_DW - 3;
localparam LUT_IN_DW = ATAN_IN_DW;

reg [2*ATAN_IN_DW : 0] C0_times_conjC1;

function [LUT_IN_DW - 1 : 0] abs;
    input signed [LUT_IN_DW - 1 : 0] arg;
begin
    abs = arg[LUT_IN_DW-1] ? -arg : arg;
end
endfunction

function sign;
    input [LUT_IN_DW - 1 : 0] arg;
begin
    sign = !arg[LUT_IN_DW-1];
end
endfunction

// TODO: this multiplier can run on a slower clock, ie 3.84 MHz
// so that it can be synthesized easily without any DSP48 units
complex_multiplier #(
    .OPERAND_WIDTH_A(C_DW/2),
    .OPERAND_WIDTH_B(C_DW/2),
    .OPERAND_WIDTH_OUT(ATAN_IN_DW),
    .BLOCKING(0)
)
complex_multiplier_i(
    .aclk(clk_i),
    .aresetn(reset_ni),
    .s_axis_a_tdata(C0_i),
    .s_axis_a_tvalid(valid_i),
    .s_axis_b_tdata(C1_conj),
    .s_axis_b_tvalid(valid_i),
    .m_axis_dout_tdata(C0_times_conjC1),
    .m_axis_dout_tvalid(mult_valid_out)
);
reg signed [ATAN_IN_DW - 1 : 0] prod_im, prod_re;


localparam MAX_LUT_IN_VAL = (2**(LUT_IN_DW-1) - 1);
reg [LUT_OUT_DW - 1 : 0]  atan_lut[0 : MAX_LUT_IN_VAL];
localparam MAX_LUT_OUT_VAL = (2**(LUT_OUT_DW-1) - 1);
initial begin
    $display("tan lut has %d entries", MAX_LUT_IN_VAL+1);
    for (integer i = 0; i <= MAX_LUT_IN_VAL; i = i + 1) begin
        atan_lut[i] = $atan($itor(i)/MAX_LUT_IN_VAL) / 3.14159 * 4 * MAX_LUT_OUT_VAL;
        // $display("atan %d  = %d", i, atan_lut[i]);
    end
end
wire signed [CFO_DW-1 : 0] LUT_OUT_EXT = {{(3){atan_lut[div][LUT_OUT_DW-1]}}, atan_lut[div]};
reg [LUT_IN_DW-1 : 0] div;
reg signed [CFO_DW-1 : 0] atan;

reg [LUT_IN_DW - 1 : 0] numerator, denominator;
reg inv_div_result;
localparam signed [CFO_DW - 1 : 0] PI_HALF = 2 ** (CFO_DW - 2) - 1;
localparam signed [CFO_DW - 1 : 0] PI_QUARTER = 2 ** (CFO_DW - 3) - 1;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        valid_o <= '0;
        CFO_norm_o <= '0;
        state <= WAIT_FOR_MULT;
        inv_div_result <= '0;
        atan <= '0;
    end else begin
        case (state)
        WAIT_FOR_MULT : begin
            if (mult_valid_out) begin
                prod_im <= C0_times_conjC1[2*ATAN_IN_DW - 1 : ATAN_IN_DW];
                prod_re <= C0_times_conjC1[ATAN_IN_DW - 1 : 0];
                state <= CALC_DIV;
            end
            valid_o <= '0;
        end
        CALC_DIV : begin
            $display("prod_im = %d  abs(prod_im) = %d", prod_im, abs(prod_im));
            $display("prod_re = %d  abs(prod_re) = %d", prod_re, abs(prod_re));
            if (abs(prod_re) > abs(prod_im)) begin
                numerator = abs(prod_im);
                denominator = abs(prod_re);
                inv_div_result <= '0;
            end else begin
                $display("reverse");
                inv_div_result <= 1;
                numerator = abs(prod_re);
                denominator = abs(prod_im);
            end
            div <= (numerator * MAX_LUT_IN_VAL) / denominator;
            $display("%d/%d = %d", numerator, denominator, (numerator * MAX_LUT_IN_VAL) / denominator);
            state <= CALC_ATAN;
        end
        CALC_ATAN: begin
            $display("sign(re) = %d  sign(im) = %d", sign(prod_re), sign(prod_im));
            if (inv_div_result)         atan = PI_QUARTER - LUT_OUT_EXT;
            else                        atan = LUT_OUT_EXT;

            // 1. quadrant
                // do nothing
            // 2. quadrant      
            if (sign(prod_im) && (!sign(prod_re)))              atan = -atan + PI_HALF;
            // 3. quadrant
            else if ((!sign(prod_im)) && (!sign(prod_re)))      atan = atan - PI_HALF;
            // 4. quadrant
            else if ((!sign(prod_im)) && sign(prod_re))         atan = -atan;

            else  $display("ERROR!");
            state <= OUTPUT;
        end
        OUTPUT : begin
            CFO_norm_o <= atan;
            valid_o <= 1;
            state <= WAIT_FOR_MULT;
        end
        default : begin end
        endcase
    end
end

`ifdef COCOTB_SIM
initial begin
  $dumpfile ("debug.vcd");
  $dumpvars (0, CFO_calc);
end
`endif

endmodule
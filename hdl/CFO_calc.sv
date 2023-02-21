`timescale 1ns / 1ns

module CFO_calc
#(
    parameter C_DW = 32,
    parameter CFO_DW = 20,
    parameter DDS_DW = 20,
    localparam SAMPLE_RATE = 3840000
)
(
    input                                                       clk_i,
    input                                                       reset_ni,
    input                   [C_DW - 1 : 0]                      C0_i,
    input                   [C_DW - 1 : 0]                      C1_i,
    input                                                       valid_i,

    output  reg  signed     [CFO_DW - 1 : 0]                    CFO_angle_o,
    output  reg  signed     [DDS_DW - 1 : 0]                    CFO_DDS_inc_o,
    output  reg                                                 valid_o
);

reg [C_DW - 1 : 0] C0, C1;
wire [C_DW - 1 : 0] C1_conj = {-C1[C_DW-1 : C_DW/2], C1[C_DW/2-1 : 0]};
reg mult_valid_out;

reg [3 : 0]  state;
localparam WAIT_FOR_INPUT = 4'b0000;
localparam INPUT_SCALING  = 4'b0001;
localparam WAIT_FOR_MULT  = 4'b0010;
localparam CALC_DIV       = 4'b0011;
localparam CALC_DIV2      = 4'b0100;
localparam CALC_ATAN      = 4'b0101;
localparam OUTPUT         = 4'b0110;

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
reg mult_valid_in;
complex_multiplier #(
    .OPERAND_WIDTH_A(C_DW/2),       // TODO: input width can be reduced, because of dynamic scaling
    .OPERAND_WIDTH_B(C_DW/2),
    .OPERAND_WIDTH_OUT(ATAN_IN_DW),
    .BLOCKING(0),
    .BYTE_ALIGNED(0)
)
complex_multiplier_i(
    .aclk(clk_i),
    .aresetn(reset_ni),
    .s_axis_a_tdata(C0),
    .s_axis_a_tvalid(mult_valid_in),
    .s_axis_b_tdata(C1_conj),
    .s_axis_b_tvalid(mult_valid_in),
    .m_axis_dout_tdata(C0_times_conjC1),
    .m_axis_dout_tvalid(mult_valid_out)
);
reg signed [ATAN_IN_DW - 1 : 0] prod_im, prod_re;


localparam MAX_LUT_IN_VAL = (2**LUT_IN_DW - 1);
reg [LUT_OUT_DW - 1 : 0]  atan_lut[0 : MAX_LUT_IN_VAL];
localparam MAX_LUT_OUT_VAL = (2**(LUT_OUT_DW - 1) - 1);
initial begin
    $display("tan lut has %d entries", MAX_LUT_IN_VAL+1);
    for (integer i = 0; i <= MAX_LUT_IN_VAL; i = i + 1) begin
        atan_lut[i] = $atan($itor(i)/MAX_LUT_IN_VAL) / 3.14159 * 4 * MAX_LUT_OUT_VAL;
        // $display("atan %d  = %d", i, atan_lut[i]);
    end
end
wire signed [CFO_DW - 1 : 0] LUT_OUT_EXT = {{(3){atan_lut[div][LUT_OUT_DW - 1]}}, atan_lut[div]};
reg [LUT_IN_DW - 1 : 0] div;
reg [$clog2(LUT_IN_DW) : 0] div_pos;
reg signed [CFO_DW - 1 : 0] atan;

function is_bit_used;
    input [C_DW / 2 - 1 : 0] data;
    input [$clog2(C_DW/2) - 1 : 0] MSB_pos;
begin
    if (data[C_DW / 2 - 1]) begin // neg. number
        is_bit_used = !data[MSB_pos];
    end else begin            // pos. number
        is_bit_used = data[MSB_pos];
    end
end
endfunction

reg [LUT_IN_DW - 1 : 0] numerator, denominator;
reg [LUT_IN_DW + ATAN_IN_DW - 1 : 0] numerator_wide, denominator_wide;
reg inv_div_result;
localparam signed [CFO_DW - 1 : 0] PI_HALF = 2 ** (CFO_DW - 2) - 1;
localparam signed [CFO_DW - 1 : 0] PI_QUARTER = 2 ** (CFO_DW - 3) - 1;
reg [$clog2(C_DW/2) - 1 : 0] input_max_used_MSB;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        valid_o <= '0;
        CFO_angle_o <= '0;
        CFO_DDS_inc_o <= '0;
        state <= WAIT_FOR_INPUT;
        inv_div_result <= '0;
        atan = '0;
        input_max_used_MSB <= C_DW / 2 - 2;  // dont need to test the MSB
        mult_valid_in <= '0;
    end else begin
        case (state)
        WAIT_FOR_INPUT : begin
            valid_o <= 0;
            if (valid_i) begin
                state <= INPUT_SCALING;
                // mult_valid_in <= 1;
                // state <= WAIT_FOR_MULT;
                // $display("go to state INPUT_SCALING");
                C0 <= C0_i;
                C1 <= C1_i;
                input_max_used_MSB <= C_DW / 2 - 2;  // dont need to test the MSB
            end
        end
        INPUT_SCALING : begin
            // $display("is used %x bit %d = %d",C0[C_DW - 1 : C_DW / 2], input_max_used_MSB, is_bit_used(C0[C_DW - 1 : C_DW / 2], input_max_used_MSB));
            // $display("is used %x bit %d = %d",C0[C_DW / 2 - 1 : 0], input_max_used_MSB, is_bit_used(C0[C_DW / 2 - 1 : 0], input_max_used_MSB));
            // $display("is used %x bit %d = %d",C1[C_DW - 1 : C_DW / 2], input_max_used_MSB, is_bit_used(C1[C_DW - 1 : C_DW / 2], input_max_used_MSB));
            // $display("is used %x bit %d = %d",C0[C_DW / 2 - 1 : 0], input_max_used_MSB, is_bit_used(C0[C_DW / 2 - 1 : 0], input_max_used_MSB));
            if (   (!is_bit_used(C0[C_DW - 1 : C_DW / 2], input_max_used_MSB))
                && (!is_bit_used(C0[C_DW / 2 - 1 : 0], input_max_used_MSB))
                && (!is_bit_used(C1[C_DW - 1 : C_DW / 2], input_max_used_MSB))
                && (!is_bit_used(C1[C_DW / 2 - 1 : 0], input_max_used_MSB))
                && (input_max_used_MSB > 0)) begin
                input_max_used_MSB <= input_max_used_MSB - 1;
            end else begin
                C0[C_DW - 1 : C_DW / 2] <= C0[C_DW - 1 : C_DW / 2] << (C_DW / 2 - 1 - input_max_used_MSB - 1);
                C0[C_DW / 2 - 1 : 0]    <= C0[C_DW / 2 - 1 : 0]    << (C_DW / 2 - 1 - input_max_used_MSB - 1);
                C1[C_DW - 1 : C_DW / 2] <= C1[C_DW - 1 : C_DW / 2] << (C_DW / 2 - 1 - input_max_used_MSB - 1);
                C1[C_DW / 2 - 1 : 0]    <= C1[C_DW / 2 - 1 : 0]    << (C_DW / 2 - 1 - input_max_used_MSB - 1);
                mult_valid_in <= 1;
                state <= WAIT_FOR_MULT;
                // $display("go to state WAIT_FOR_MULT");
            end
        end
        WAIT_FOR_MULT : begin
            mult_valid_in <= '0;
            if (mult_valid_out) begin
                prod_im <= C0_times_conjC1[2*ATAN_IN_DW - 1 : ATAN_IN_DW];
                prod_re <= C0_times_conjC1[ATAN_IN_DW - 1 : 0];
                state <= CALC_DIV;
                // $display("go to state CALC_DIV");
            end
        end
        CALC_DIV : begin
            // $display("prod_im = %d  abs(prod_im) = %d", prod_im, abs(prod_im));
            // $display("prod_re = %d  abs(prod_re) = %d", prod_re, abs(prod_re));
            if (abs(prod_re) > abs(prod_im)) begin
                numerator = abs(prod_im);
                denominator = abs(prod_re);
                inv_div_result <= '0;
            end else begin
                // $display("reverse");
                inv_div_result <= 1;
                numerator = abs(prod_re);
                denominator = abs(prod_im);
            end
            div <= '0;
            if (numerator == 0 || denominator == 0) begin
                atan = '0;
                state <= OUTPUT;
            end else begin
                div_pos <= LUT_IN_DW;
                numerator_wide <= (numerator <<< LUT_IN_DW) - 1;
                denominator_wide <= {{(ATAN_IN_DW){1'b0}}, denominator};  // explicit zero padding is actually not needed
                state <= CALC_DIV2;
            end
            // div <= (numerator * MAX_LUT_IN_VAL) / denominator;
            // $display("%d/%d = %d", numerator, denominator, (numerator * MAX_LUT_IN_VAL) / denominator);
            // state <= CALC_ATAN;
        end
        CALC_DIV2: begin
            if (numerator_wide >= (denominator_wide <<< div_pos)) begin
                numerator_wide <= numerator_wide - (denominator_wide <<< div_pos);
                div <= div + 2**div_pos;
            end
            div_pos <= div_pos - 1;
            if (div_pos == 0)   state <= CALC_ATAN;
        end
        CALC_ATAN: begin
            $display("atan lut-index = %d", div);
            // $display("sign(re) = %d  sign(im) = %d", sign(prod_re), sign(prod_im));
            if (inv_div_result)         atan = PI_QUARTER - LUT_OUT_EXT;
            else                        atan = LUT_OUT_EXT;

            // 1. quadrant
            if (sign(prod_im) && (sign(prod_re))) ;
                // do nothing
            // 2. quadrant      
            else if (sign(prod_im) && (!sign(prod_re)))         atan = -atan + PI_HALF;
            // 3. quadrant
            else if ((!sign(prod_im)) && (!sign(prod_re)))      atan = atan - PI_HALF;
            // 4. quadrant
            else if ((!sign(prod_im)) && sign(prod_re))         atan = -atan;

            state <= OUTPUT;
        end
        OUTPUT : begin
            CFO_angle_o <= atan;
            if (CFO_DW >= DDS_DW) begin
                // take upper MSBs
                CFO_DDS_inc_o <= atan[CFO_DW - 1 -: DDS_DW] >>> 6; // >>> 6 for divide by 64
            end else begin
                // sign extend
                CFO_DDS_inc_o <= {{(DDS_DW - CFO_DW){atan[CFO_DW - 1]}}, atan} >>> 6;
            end
            valid_o <= 1;
            state <= WAIT_FOR_INPUT;
        end
        default : begin end
        endcase
    end
end

endmodule
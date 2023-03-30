`timescale 1ns / 1ns

module CFO_calc
#(
    parameter C_DW = 32,
    parameter CFO_DW = 20,
    parameter DDS_DW = 20,
    parameter ATAN_IN_DW = 8,
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
localparam CALC_ATAN      = 4'b0101;
localparam OUTPUT         = 4'b0110;

reg [2*ATAN_IN_DW : 0] C0_times_conjC1;

reg atan_valid_in;
reg atan2_valid_out;
reg signed [CFO_DW - 1 : 0] atan2_out;
reg signed [CFO_DW - 1 : 0] atan;
reg signed [ATAN_IN_DW - 1 : 0] prod_im, prod_re;
atan2 #(
    .INPUT_WIDTH(ATAN_IN_DW),
    .LUT_DW(ATAN_IN_DW),
    .OUTPUT_WIDTH(CFO_DW)
)
atan2_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),

    .numerator_i(prod_im),
    .denominator_i(prod_re),
    .valid_i(atan_valid_in),

    .angle_o(atan2_out),
    .valid_o(atan2_valid_out)
);


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

function is_bit_used;
    input [C_DW / 2 - 1 : 0] data;
    input [$clog2(C_DW/2) - 1 : 0] MSB_pos;
begin
    if (data[C_DW / 2 - 1]) begin   // neg. number
        is_bit_used = !data[MSB_pos];
    end else begin                  // pos. number
        is_bit_used = data[MSB_pos];
    end
end
endfunction

reg [$clog2(C_DW/2) - 1 : 0] input_max_used_MSB;
wire signed [CFO_DW - 1 : 0] atan_rshift7 = atan >>> 7;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        valid_o <= '0;
        // CFO_angle_o <= '0;
        CFO_DDS_inc_o <= '0;
        state <= WAIT_FOR_INPUT;
        input_max_used_MSB <= C_DW / 2 - 2;  // dont need to test the MSB
        mult_valid_in <= '0;
        atan_valid_in <= '0;
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
                atan_valid_in <= 1;
                state <= CALC_ATAN;
            end
        end
        CALC_ATAN: begin
            atan_valid_in <= '0;
            if (atan2_valid_out) begin
                atan <= atan2_out;
                state <= OUTPUT;
            end
        end
        OUTPUT : begin
            if (CFO_DW >= DDS_DW) begin
                // take upper MSBs
                CFO_DDS_inc_o <= atan_rshift7[CFO_DW - 1 -: DDS_DW]; // >>> 7 for divide / 64 / 2
            end else begin
                // sign extend
                CFO_DDS_inc_o <= {{(DDS_DW - CFO_DW){atan[CFO_DW - 1]}}, atan_rshift7};
            end
            CFO_angle_o <= atan;
            valid_o <= 1;
            state <= WAIT_FOR_INPUT;
        end
        default : begin end
        endcase
    end
end

endmodule
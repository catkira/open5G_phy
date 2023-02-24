`timescale 1ns / 1ns
// This core calculates the arctan by using the atan core
// Copyright (C) 2023  Benjamin Menkuec
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.


module atan2 #(
    parameter                               INPUT_WIDTH = 16,
    parameter                               LUT_DW = 16,
    parameter                               OUTPUT_WIDTH = 16
)
(
    input                                           clk_i,
    input                                           reset_ni,

    input       signed  [INPUT_WIDTH - 1 : 0]       numerator_i,
    input       signed  [INPUT_WIDTH - 1 : 0]       denominator_i,
    input                                           valid_i,

    output reg  signed  [OUTPUT_WIDTH - 1 : 0]      angle_o,
    output reg                                      valid_o
);

function [INPUT_WIDTH - 1 : 0] abs;
    input signed [INPUT_WIDTH - 1 : 0] arg;
begin
    abs = arg[INPUT_WIDTH-1] ? -arg : arg;
end
endfunction

function sign;
    input [LUT_DW - 1 : 0] arg;
begin
    sign = !arg[LUT_DW-1];
end
endfunction

localparam ATAN_OUT_DW = OUTPUT_WIDTH - 3;

reg div_valid_in;
reg div_valid_out;
reg [LUT_DW - 1 : 0] div_result;
reg [2 : 0] div_user_out;
div #(
    .INPUT_WIDTH(INPUT_WIDTH + LUT_DW),
    .RESULT_WIDTH(LUT_DW),
    .PIPELINED(1),
    .USER_WIDTH(3)
)
div_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),

    .numerator_i(numerator_wide),
    .denominator_i(denominator_wide),
    .user_i({inv_div_result, sign(numerator_i), sign(denominator_i)}),
    .valid_i(div_valid_in),

    .result_o(div_result),
    .user_o(div_user_out),
    .valid_o(div_valid_out)
);

reg [LUT_DW - 1 : 0] atan_arg;
reg [ATAN_OUT_DW - 1 : 0] atan_angle;
reg atan_valid;
atan #(
    .INPUT_WIDTH(LUT_DW),
    .OUTPUT_WIDTH(ATAN_OUT_DW)
)
atan_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),

    .arg_i(atan_arg),
    .angle_o(atan_angle)
);
wire [OUTPUT_WIDTH - 1 : 0] atan_angle_ext = {{(3){1'b0}}, atan_angle};

reg [1 : 0] state;
reg signed  [INPUT_WIDTH - 1 : 0]  numerator;
reg signed  [INPUT_WIDTH - 1 : 0]  denominator;
reg [LUT_DW + INPUT_WIDTH - 1 : 0] numerator_wide, denominator_wide;
reg inv_div_result;
reg [2 : 0] user_out_N;
reg signed [OUTPUT_WIDTH - 1 : 0] atan2_out;
reg                               atan2_valid;
localparam signed [OUTPUT_WIDTH - 1 : 0] PI_HALF = 2 ** (OUTPUT_WIDTH - 1) - 1;
localparam signed [OUTPUT_WIDTH - 1 : 0] PI_QUARTER = 2 ** (OUTPUT_WIDTH - 2) - 1;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        angle_o <= '0;
        state <= '0;
        atan2_out = '0;
        atan_valid <= '0;
        atan2_valid <= '0;
    end else begin
        // stage 0
        if (abs(denominator_i) > abs(numerator_i)) begin
            numerator = abs(numerator_i);
            denominator = abs(denominator_i);
            inv_div_result <= 0;
        end else begin
            // $display("reverse");
            inv_div_result <= 1;
            numerator = abs(denominator_i);
            denominator = abs(numerator_i);
        end        
        
        div_valid_in <= valid_i;
        numerator_wide <= (numerator << LUT_DW) - 1;
        denominator_wide <= {{(LUT_DW){1'b0}}, denominator};  // explicit zero padding is actually not needed   

        // stage n
        atan_arg <= div_result;
        user_out_N <= div_user_out;
        atan_valid <= div_valid_out;

        // stage n + 1
        atan2_valid <= atan_valid;
        if (user_out_N[2])     atan2_out = PI_QUARTER - atan_angle_ext;
        else                   atan2_out = atan_angle_ext;
        // 1. quadrant
        if      (user_out_N[1] && user_out_N[0]) begin end
            // do nothing
        // 2. quadrant      
        else if (user_out_N[1] && (!user_out_N[0]))         atan2_out = -atan2_out + PI_HALF;
        // 3. quadrant
        else if ((!user_out_N[1]) && (!user_out_N[0]))      atan2_out = atan2_out - PI_HALF;
        // 4. quadrant
        else if ((!user_out_N[1]) && (user_out_N[0]))       atan2_out = -atan2_out;

        // stage n + 2
        angle_o <= atan2_out;
        valid_o <= atan2_valid;
    end
end

endmodule
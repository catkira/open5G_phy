`timescale 1ns / 1ns
// This core calculates the arctan by using a LUT
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


module atan #(
    parameter                               INPUT_WIDTH = 16,
    parameter                               OUTPUT_WIDTH = 16
)
(
    input                                   clk_i,
    input                                   reset_ni,

    input       [INPUT_WIDTH - 1 : 0]       arg_i,

    output      [OUTPUT_WIDTH - 1 : 0]      angle_o
);

localparam MAX_LUT_IN_VAL = (2**INPUT_WIDTH - 1);
localparam MAX_LUT_OUT_VAL = (2**OUTPUT_WIDTH - 1);
reg [OUTPUT_WIDTH - 1 : 0]  atan_lut[0 : MAX_LUT_IN_VAL];

initial begin
    $display("tan lut has %d entries", MAX_LUT_IN_VAL+1);
    for (integer i = 0; i <= MAX_LUT_IN_VAL; i = i + 1) begin
        atan_lut[i] = $atan($itor(i)/MAX_LUT_IN_VAL) / (3.14159 / 4) * MAX_LUT_OUT_VAL;
        // $display("atan %d  = %d", i, atan_lut[i]);
    end
end

assign angle_o = atan_lut[arg_i];


// always @(posedge clk_i) begin
//     if (!reset_ni) begin
//         angle_o <= '0;
//     end else begin
//         angle_o <= atan_lut[arg_i];
//     end
// end

endmodule
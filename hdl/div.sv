`timescale 1ns / 1ns
// This is a divider for positive integer numbers
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

module div #(
    parameter   INPUT_WIDTH = 16,
    parameter   RESULT_WIDTH = 16,
    parameter   PIPELINED = 0
)
(
    input                                   clk_i,
    input                                   reset_ni,

    input           [INPUT_WIDTH - 1 : 0]   numerator_i,
    input           [INPUT_WIDTH - 1 : 0]   denominator_i,
    input                                   valid_i,

    output  reg     [RESULT_WIDTH - 1 : 0]  result_o,
    output  reg                             valid_o
);

if (PIPELINED) begin
    always @(posedge clk_i) begin
    end
end else begin
    reg [1 : 0] state;
    reg [INPUT_WIDTH - 1 : 0] numerator;
    reg [INPUT_WIDTH + RESULT_WIDTH - 1 : 0] denominator;
    reg [$clog2(RESULT_WIDTH) : 0] div_pos;

    always @(posedge clk_i) begin
        if (!reset_ni) begin
            result_o <= '0;
            valid_o <= '0;
            state <= '0;
            div_pos <= '0;
        end else begin
            case(state)
                0 : begin
                    if (valid_i) begin
                        if ((numerator_i == 0) || (denominator_i == 0)) begin
                            result_o <= '0;
                            valid_o <= 1;
                        end else begin
                            numerator <= numerator_i;
                            denominator <= denominator_i;
                            result_o <= '0;
                            div_pos <= RESULT_WIDTH - 1;
                            state <= 1;
                            valid_o <= '0;
                            // $display("div: calculate %d / %d", numerator_i, denominator_i);
                        end
                    end else begin
                        valid_o <= '0;
                    end
                end
                1 : begin
                    if (numerator >= (denominator << div_pos)) begin
                        numerator <= numerator - (denominator << div_pos);
                        result_o <= result_o + 2**div_pos;
                    end
                    div_pos <= div_pos - 1;
                    if (div_pos == 0) begin
                        state <= 0;
                        valid_o <= '1;
                    end
                end
            endcase
        end
    end
end

endmodule
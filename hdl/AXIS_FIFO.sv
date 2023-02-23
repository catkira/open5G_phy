`timescale 1ns / 1ns
// This is a very simple async clock FIFO
// It currently assumes that out_clk is faster than clk_i
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


// This core encapsulates a AXI lite slave interface and provides a simple core interface
// 
// The simple client core interface can be used to write or write to specific addresses.
// The size of each read or write is fixed 4 byte.
// This core will wait for 16 clks to receive a rack or wack from the client core,
// if it does not receive one, it will ack anyway.

module AXIS_FIFO #(
    parameter DATA_WIDTH = 16,
    parameter FIFO_LEN = 8      // has to be power of 2 !
)
(
    input                                       clk_i,
    input                                       reset_ni,

    input           [DATA_WIDTH - 1 : 0]        s_axis_in_tdata,
    input                                       s_axis_in_tvalid,

    input   reg                                 out_clk_i,
    output  reg     [DATA_WIDTH - 1 : 0]        m_axis_out_tdata,
    output  reg                                 m_axis_out_tvalid
);

localparam PTR_WIDTH = $clog2(FIFO_LEN);

function [PTR_WIDTH - 1 : 0] g2b;
	input [PTR_WIDTH - 1 : 0] g;
	reg   [PTR_WIDTH - 1 : 0] b;
	integer i;
	begin
		b[PTR_WIDTH-1] = g[PTR_WIDTH-1];
		for (i = PTR_WIDTH - 2; i >= 0; i =  i - 1)
			b[i] = b[i + 1] ^ g[i];
		g2b = b;
	end
endfunction

function [PTR_WIDTH - 1 : 0] b2g;
	input [PTR_WIDTH - 1 : 0] b;
	reg [PTR_WIDTH - 1 : 0] g;
	integer i;
	begin
		g[PTR_WIDTH-1] = b[PTR_WIDTH-1];
		for (i = PTR_WIDTH - 2; i >= 0; i = i -1)
				g[i] = b[i + 1] ^ b[i];
		b2g = g;
	end
endfunction

reg [PTR_WIDTH - 1 : 0]             wr_ptr_grey;
reg [DATA_WIDTH - 1  : 0]           mem [0 : FIFO_LEN - 1];

always @(posedge clk_i) begin
    if (!reset_ni) begin
        wr_ptr_grey <= '0;
        for(integer i = 0; i < FIFO_LEN; i = i + 1)   mem[i] <= '0;
    end else begin
        if (s_axis_in_tvalid) begin
            mem[g2b(wr_ptr_grey)] <= s_axis_in_tdata;
            wr_ptr_grey <= b2g(g2b(wr_ptr_grey) + 1);
        end
    end
end

reg [PTR_WIDTH - 1 : 0]   rd_ptr;

always @(posedge out_clk_i) begin
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
        m_axis_out_tvalid <= '0;
        rd_ptr <= '0;
    end else begin
        if (rd_ptr != g2b(wr_ptr_grey)) begin
            m_axis_out_tdata <= mem[rd_ptr];
            m_axis_out_tvalid <= 1;
            rd_ptr <= rd_ptr + 1;
        end else begin
            m_axis_out_tvalid <= 0;
        end
    end
end

endmodule
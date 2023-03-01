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

module AXIS_FIFO #(
    parameter DATA_WIDTH = 16,
    parameter FIFO_LEN = 8,      // has to be power of 2 !
    parameter USER_WIDTH = 1,
    parameter ASYNC = 1
)
(
    input                                       clk_i,
    input                                       reset_ni,

    input           [DATA_WIDTH - 1 : 0]        s_axis_in_tdata,
    input           [USER_WIDTH - 1 : 0]        s_axis_in_tuser,
    input                                       s_axis_in_tvalid,
    output  reg                                 s_axis_in_tfull,

    input                                       out_clk_i,
    input                                       m_axis_out_tready,
    output  reg     [DATA_WIDTH - 1 : 0]        m_axis_out_tdata,
    output  reg     [USER_WIDTH - 1 : 0]        m_axis_out_tuser,
    output  reg                                 m_axis_out_tvalid,
    output  reg     [$clog2(FIFO_LEN) - 1 : 0]  m_axis_out_tlevel,
    output  reg                                 m_axis_out_tempty
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


reg [DATA_WIDTH - 1  : 0]           mem [0 : FIFO_LEN - 1];
reg [USER_WIDTH - 1  : 0]           mem_user [0 : FIFO_LEN - 1];

if (ASYNC) begin
    reg [PTR_WIDTH - 1 : 0]             rd_ptr;
    reg [PTR_WIDTH - 1 : 0]             wr_ptr_grey;    
    always @(posedge clk_i) begin
        if (!reset_ni) begin
            wr_ptr_grey <= '0;
            for(integer i = 0; i < FIFO_LEN; i = i + 1)   begin
                mem[i] = '0;  // Non-delayed for verilator
                if (USER_WIDTH > 0)  mem_user[i] = '0;
            end
        end else begin
            if (s_axis_in_tvalid) begin
                mem[g2b(wr_ptr_grey)] <= s_axis_in_tdata;
                if (USER_WIDTH > 0)  mem_user[g2b(wr_ptr_grey)] <= s_axis_in_tuser;
                wr_ptr_grey <= b2g(g2b(wr_ptr_grey) + 1);
            end
        end
    end


    always @(posedge out_clk_i) begin
        if (!reset_ni) begin
            m_axis_out_tdata <= '0;
            m_axis_out_tvalid <= '0;
            m_axis_out_tuser <= '0;
            rd_ptr <= '0;
        end else begin
            if ((rd_ptr != g2b(wr_ptr_grey)) && m_axis_out_tready) begin
                m_axis_out_tdata <= mem[rd_ptr];
                if (USER_WIDTH > 0)  m_axis_out_tuser <= mem_user[rd_ptr];
                m_axis_out_tvalid <= 1;
                rd_ptr <= rd_ptr + 1;
            end else begin
                m_axis_out_tvalid <= 0;
            end
        end
    end

    // TODO: tfull, tempty, tlevel are not support for ASYNC = 1
    always @(posedge clk_i) begin
        s_axis_in_tfull <= '0;
    end

    always @(posedge out_clk_i) begin
        m_axis_out_tempty <= 1;
        m_axis_out_tlevel <= '0;
    end
end
// -----------------------------------------------------------------------------------------------------
// SYNC CLOCK
else begin
    reg  [PTR_WIDTH : 0]            wr_ptr;
    reg  [PTR_WIDTH : 0]            rd_ptr;
    wire                            ptr_equal       = wr_ptr[PTR_WIDTH - 1 : 0] == rd_ptr[PTR_WIDTH - 1 : 0];
    wire [PTR_WIDTH : 0]            ptr_diff        = wr_ptr[PTR_WIDTH : 0] - rd_ptr[PTR_WIDTH : 0];
    wire                            ptr_msb_equal   = wr_ptr[PTR_WIDTH] == rd_ptr[PTR_WIDTH];
    wire [PTR_WIDTH - 1: 0]         wr_ptr_addr     = wr_ptr[PTR_WIDTH - 1 : 0];
    wire [PTR_WIDTH - 1: 0]         rd_ptr_addr     = rd_ptr[PTR_WIDTH - 1 : 0];
    wire                            overflow        = s_axis_in_tfull && s_axis_in_tvalid;
    wire                            underflow       = (!s_axis_in_tfull) && m_axis_out_tvalid;

    always @(posedge clk_i) begin
        if (!reset_ni) begin
            wr_ptr <= '0;
            for(integer i = 0; i < FIFO_LEN; i = i + 1) begin
                mem[i] = '0;  // Non-delayed for verilator
                if (USER_WIDTH > 0)  mem_user[i] = '0;
            end
        end else begin
            if (s_axis_in_tvalid) begin
                mem[wr_ptr_addr] <= s_axis_in_tdata;
                if (USER_WIDTH > 0)  mem_user[wr_ptr_addr] <= s_axis_in_tuser;
                wr_ptr <= wr_ptr + 1;
            end
        end
    end

    wire empty = ptr_equal && ptr_msb_equal;

    always @(posedge clk_i) begin
        if (!reset_ni) begin
            m_axis_out_tdata <= '0;
            m_axis_out_tvalid <= '0;
            m_axis_out_tuser <= '0;            
            rd_ptr <= '0;
        end else begin
            // output tdata and tuser as early as possible, even if tready is not yet asserted
            // this is a feature and can be used to peek inside the fifo without taking data out !
            m_axis_out_tdata <= mem[rd_ptr_addr];
            if (USER_WIDTH > 0)  m_axis_out_tuser <= mem_user[rd_ptr_addr];                

            if ((!empty) && m_axis_out_tready) begin
                m_axis_out_tvalid <= 1;
                rd_ptr <= rd_ptr + 1;
            end else begin
                m_axis_out_tvalid <= 0;
            end
        end
    end

    always @(posedge clk_i) begin
        if (!reset_ni) begin
            s_axis_in_tfull <= '0;
            m_axis_out_tempty <= 1;
            m_axis_out_tlevel <= '0;
        end else begin
            s_axis_in_tfull <= ptr_equal && (!ptr_msb_equal);
            m_axis_out_tempty <= empty;
            m_axis_out_tlevel <= ptr_diff[PTR_WIDTH - 1 : 0];
        end
    end
end

endmodule
`timescale 1ns / 1ns
// This is a very simple FIFO.
// Sync and async clock mode is supported. Operation mode is cut-through.
// Async clock mode currently assumes that out_clk is faster than clk_i
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
    input                                               clk_i,
    input                                               s_reset_ni,

    input           [DATA_WIDTH - 1 : 0]                s_axis_in_tdata,
    input           [USER_WIDTH - 1 : 0]                s_axis_in_tuser,
    input                                               s_axis_in_tlast,
    input                                               s_axis_in_tvalid,
    output                                              s_axis_in_tfull,

    input                                               out_clk_i,
    input                                               m_reset_ni,
    input                                               m_axis_out_tready,
    output  reg     [DATA_WIDTH - 1 : 0]                m_axis_out_tdata,
    output  reg     [USER_WIDTH - 1 : 0]                m_axis_out_tuser,
    output  reg                                         m_axis_out_tlast,
    output  reg                                         m_axis_out_tvalid,
    output          [$clog2(FIFO_LEN) - 1 : 0]          m_axis_out_tlevel,
    output                                              m_axis_out_tempty
);

localparam PTR_WIDTH = $clog2(FIFO_LEN);

function [PTR_WIDTH : 0] g2b;
	input [PTR_WIDTH : 0] g;
	reg   [PTR_WIDTH : 0] b;
	integer i;
	begin
		b[PTR_WIDTH] = g[PTR_WIDTH];
		for (i = PTR_WIDTH - 1; i >= 0; i =  i - 1)
			b[i] = b[i + 1] ^ g[i];
		g2b = b;
	end
endfunction

function [PTR_WIDTH : 0] b2g;
	input [PTR_WIDTH : 0] b;
	reg [PTR_WIDTH : 0] g;
	integer i;
	begin
		g[PTR_WIDTH] = b[PTR_WIDTH];
		for (i = PTR_WIDTH - 1; i >= 0; i = i -1)
				g[i] = b[i + 1] ^ b[i];
		b2g = g;
	end
endfunction

if (ASYNC) begin  : GEN_ASYNC
    (* ram_style = "block" *)
    reg [DATA_WIDTH + USER_WIDTH- 1  : 0]           mem[0 : FIFO_LEN - 1];

    reg [PTR_WIDTH : 0]                 rd_ptr;
    reg [PTR_WIDTH : 0]                 wr_ptr_grey;
    wire [PTR_WIDTH : 0]                wr_ptr          = g2b(wr_ptr_grey);
    wire [PTR_WIDTH - 1: 0]             wr_ptr_addr     = wr_ptr[PTR_WIDTH - 1 : 0];
    wire [PTR_WIDTH - 1: 0]             rd_ptr_addr     = rd_ptr[PTR_WIDTH - 1 : 0];
    reg [PTR_WIDTH : 0]                 wr_ptr_f, wr_ptr_ff;
    wire [PTR_WIDTH : 0]                wr_ptr_master   = g2b(wr_ptr_ff);
    wire                                empty           = wr_ptr_master == rd_ptr;

    always @(posedge clk_i) begin
        if (!s_reset_ni) wr_ptr_grey <= '0;
        else if (s_axis_in_tvalid) wr_ptr_grey <= b2g(g2b(wr_ptr_grey) + 1);
    end

    always @(posedge clk_i) begin
        if (USER_WIDTH == 0)    mem[wr_ptr_addr] <= s_axis_in_tdata;
        else                    mem[wr_ptr_addr] <= {s_axis_in_tuser, s_axis_in_tdata};
    end    

    always @(posedge out_clk_i) begin
        if (!m_reset_ni) begin
            wr_ptr_f <= '0;
            wr_ptr_ff <= '0;
        end else begin
            wr_ptr_f <= wr_ptr_grey;
            wr_ptr_ff <= wr_ptr_f;
        end
    end

    wire [DATA_WIDTH + USER_WIDTH - 1 : 0] rd_data = mem[rd_ptr_addr];
    always @(posedge out_clk_i) begin
        if (!m_reset_ni) begin
            m_axis_out_tdata <= '0;
            rd_ptr <= '0;
            m_axis_out_tvalid <= '0;
        end else begin
            m_axis_out_tvalid <= !empty;
            // read new data if fifo is not empty and if there is space in the output pipeline
            if (!empty && ((!m_axis_out_tvalid) || m_axis_out_tready)) begin
                if (USER_WIDTH == 0) begin
                    m_axis_out_tdata <= rd_data;
                end else begin
                    m_axis_out_tdata <= rd_data[DATA_WIDTH - 1 : 0];
                    m_axis_out_tuser <= rd_data[DATA_WIDTH - USER_WIDTH - 1 -: USER_WIDTH];
                end
                rd_ptr <= rd_ptr + 1;
            end
        end
    end

    // TODO: tfull, tlast, level are not support for ASYNC = 1
    assign m_axis_out_tlevel = '0;
    assign m_axis_out_tempty = empty;
    assign s_axis_in_tfull = '0;
    always @(posedge out_clk_i) begin
        m_axis_out_tlast <= '0;
    end
end
// -----------------------------------------------------------------------------------------------------
// SYNC CLOCK
else begin : GEN_SYNC
    reg [DATA_WIDTH - 1  : 0]           mem[0 : FIFO_LEN - 1];
    reg [USER_WIDTH - 1  : 0]           mem_user[0 : FIFO_LEN - 1];
    reg [FIFO_LEN - 1 : 0]              mem_last;

    reg  [PTR_WIDTH : 0]            wr_ptr;
    reg  [PTR_WIDTH : 0]            rd_ptr;
    wire                            ptr_equal       = wr_ptr[PTR_WIDTH - 1 : 0] == rd_ptr[PTR_WIDTH - 1 : 0];
    wire                            ptr_msb_equal   = wr_ptr[PTR_WIDTH] == rd_ptr[PTR_WIDTH];
    wire [PTR_WIDTH - 1: 0]         wr_ptr_addr     = wr_ptr[PTR_WIDTH - 1 : 0];
    wire [PTR_WIDTH - 1: 0]         rd_ptr_addr     = rd_ptr[PTR_WIDTH - 1 : 0];
    wire                            overflow        = s_axis_in_tfull && s_axis_in_tvalid;
    wire                            empty           = wr_ptr == rd_ptr;

    always @(posedge clk_i) begin
        if (!s_reset_ni) wr_ptr <= '0;
        else if (s_axis_in_tvalid) wr_ptr <= wr_ptr + 1'b1;
    end

    always @(posedge clk_i) begin
        mem[wr_ptr_addr] <= s_axis_in_tdata;
        mem_last[wr_ptr_addr] <= s_axis_in_tlast;
        if (USER_WIDTH > 0) mem_user[wr_ptr_addr] <= s_axis_in_tuser;
    end

    wire data_in_pipeline = m_axis_out_tvalid && (!m_axis_out_tready);
    always @(posedge clk_i) begin
        if (!m_reset_ni) begin
            m_axis_out_tdata <= '0;
            m_axis_out_tlast <= '0;
            m_axis_out_tuser <= '0;
            rd_ptr <= '0;
            m_axis_out_tvalid <= '0;
        end else begin
            m_axis_out_tvalid <= !empty || data_in_pipeline;
            if (!empty && ((!m_axis_out_tvalid) || m_axis_out_tready)) begin
                m_axis_out_tdata <= mem[rd_ptr_addr];
                m_axis_out_tlast <= mem_last[rd_ptr_addr];
                if (USER_WIDTH > 0)  m_axis_out_tuser <= mem_user[rd_ptr_addr];
                rd_ptr <= rd_ptr + 1;
            end
        end
    end

    assign m_axis_out_tlevel = wr_ptr - rd_ptr + data_in_pipeline;
    assign m_axis_out_tempty = empty && (!data_in_pipeline);
    assign s_axis_in_tfull = ptr_equal && (!ptr_msb_equal);
end

endmodule
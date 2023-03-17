`timescale 1ns / 1ns
// This is a demodulator with AXI stream interface.
// It currently supports QPSK only.
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

module demap #(
    parameter IQ_DW = 16,
    parameter LLR_DW = 8
)
(
    input                                           clk_i,
    input                                           reset_ni,
    input               [IQ_DW * 2 - 1 : 0]         s_axis_in_tdata,
    input               [1 : 0]                     s_axis_in_tuser,
    input                                           s_axis_in_tlast,
    input                                           s_axis_in_tvalid,

    output              [LLR_DW - 1 : 0]            m_axis_out_tdata,
    output              [1 : 0]                     m_axis_out_tuser,
    output                                          m_axis_out_tlast,
    output                                          m_axis_out_tvalid
);

initial begin
    if (LLR_DW > IQ_DW / 2) begin
        $display("LLR_DW > IQ_DW / 2, this does not make sense!");
    end
end

reg out_fifo_valid_in;
reg [2 * 2 - 1 : 0] out_fifo_user_in;
reg out_fifo_last_in;
reg [LLR_DW * 2 - 1 : 0] out_fifo_data_in;
wire [LLR_DW - 1 : 0] llr_I;
wire [LLR_DW - 1 : 0] llr_Q;
if (LLR_DW > IQ_DW) begin
    assign llr_I = s_axis_in_tdata[IQ_DW - 1 -: IQ_DW] << (LLR_DW - IQ_DW);
    assign llr_Q = s_axis_in_tdata[IQ_DW / 2 - 1 -: IQ_DW] << (LLR_DW - IQ_DW);
end else begin
    assign llr_I = s_axis_in_tdata[IQ_DW - 1 -: LLR_DW];
    assign llr_Q = s_axis_in_tdata[IQ_DW * 2 - 1 -: LLR_DW];
end
always @(posedge clk_i) begin
    if (!reset_ni) begin
        out_fifo_valid_in <= '0;
        out_fifo_data_in <= '0;
    end else if (s_axis_in_tvalid) begin
        out_fifo_data_in <= {llr_Q, llr_I};
        out_fifo_valid_in <= 1;
        out_fifo_user_in <= {s_axis_in_tuser, s_axis_in_tuser};
        out_fifo_last_in <= s_axis_in_tlast;
    end else begin
        out_fifo_valid_in <= '0;
    end
end

AXIS_FIFO #(
    .DATA_WIDTH(LLR_DW),
    .FIFO_LEN(1024),
    .USER_WIDTH(2),
    .ASYNC(0),
    .IN_MUX(2)
)
out_fifo_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),

    .s_axis_in_tdata(out_fifo_data_in),
    .s_axis_in_tuser(out_fifo_user_in),
    .s_axis_in_tlast(out_fifo_last_in),
    .s_axis_in_tvalid(out_fifo_valid_in),

    .m_axis_out_tready(1'b1),
    .m_axis_out_tdata(m_axis_out_tdata),
    .m_axis_out_tuser(m_axis_out_tuser),
    .m_axis_out_tlast(m_axis_out_tlast),
    .m_axis_out_tvalid(m_axis_out_tvalid)
);

endmodule
`timescale 1ns / 1ns
// This is a FIFO with asymetric input / output widths.
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

module axis_fifo_asym #(
    parameter DATA_WIDTH_IN = 16,
    parameter DATA_WIDTH_OUT = 8,
    parameter ADDRESS_WIDTH_IN = 4,
    parameter USER_WIDTH_IN = 2,
    parameter ASYNC = 1,

    localparam RATIO_TYPE = DATA_WIDTH_IN >= DATA_WIDTH_OUT,
    localparam RATIO = RATIO_TYPE ? DATA_WIDTH_IN / DATA_WIDTH_OUT : DATA_WIDTH_OUT / DATA_WIDTH_IN,
    localparam USER_WIDTH_OUT = USER_WIDTH_IN == 0 ? 0 : ((RATIO_TYPE) ? USER_WIDTH_IN / RATIO : USER_WIDTH_IN * RATIO)
)
(
    input                                               clk_i,
    input                                               s_reset_ni,

    input           [DATA_WIDTH_IN - 1 : 0]             s_axis_in_tdata,
    input           [USER_WIDTH_IN - 1 : 0]             s_axis_in_tuser,
    input                                               s_axis_in_tlast,
    input                                               s_axis_in_tvalid,
    output  reg                                         s_axis_in_tfull,

    input                                               out_clk_i,
    input                                               m_reset_ni,
    input                                               m_axis_out_tready,
    output  reg     [DATA_WIDTH_OUT - 1 : 0]            m_axis_out_tdata,
    output  reg     [USER_WIDTH_OUT - 1 : 0]            m_axis_out_tuser,
    output  reg                                         m_axis_out_tlast,
    output  reg                                         m_axis_out_tvalid,
    output  reg     [ADDRESS_WIDTH_IN - 1 : 0]          m_axis_out_tlevel,
    output  reg                                         m_axis_out_tempty
);

localparam A_WIDTH = (RATIO_TYPE) ? DATA_WIDTH_OUT : DATA_WIDTH_IN;
localparam A_ADDRESS = (RATIO_TYPE) ? ADDRESS_WIDTH_IN : (ADDRESS_WIDTH_IN - $clog2(RATIO));
localparam A_USER_WIDTH = (RATIO_TYPE) ? USER_WIDTH_OUT : USER_WIDTH_IN;

wire [RATIO * A_WIDTH - 1 : 0] s_axis_data_int;
wire [RATIO-1:0] s_axis_valid_int;
wire [RATIO * A_USER_WIDTH - 1 : 0] s_axis_user_int;
wire [RATIO-1:0] s_axis_tlast_int;
wire [RATIO-1:0] s_axis_tready_int;

wire [RATIO * A_WIDTH - 1 : 0] m_axis_data_int;
wire [RATIO-1:0] m_axis_valid_int;
wire [RATIO * A_USER_WIDTH - 1 : 0] m_axis_user_int;
wire [RATIO-1:0] m_axis_ready_int;

wire user_out_ready;

reg [$clog2(RATIO) - 1 : 0] s_axis_counter;
reg [$clog2(RATIO) - 1 : 0] m_axis_counter;

genvar ii;
for (ii = 0; ii < RATIO; ii = ii + 1) begin
    AXIS_FIFO #(
        .DATA_WIDTH(A_WIDTH),
        .FIFO_LEN(2 ** A_ADDRESS),
        .USER_WIDTH(A_USER_WIDTH),
        .ASYNC(ASYNC)
    )
    axis_fifo_i(
        .clk_i(clk_i),
        .s_reset_ni(s_reset_ni),
        .s_axis_in_tdata(s_axis_data_int[A_WIDTH * ii +: A_WIDTH]),
        .s_axis_in_tvalid(s_axis_valid_int[ii]),
        .s_axis_in_tuser(s_axis_user_int[A_USER_WIDTH * ii +: A_USER_WIDTH]),
        
        .out_clk_i(out_clk_i),
        .m_reset_ni(m_reset_ni),
        .m_axis_out_tdata(m_axis_data_int[A_WIDTH * ii +: A_WIDTH]),
        .m_axis_out_tvalid(m_axis_valid_int[ii]),
        .m_axis_out_tuser(m_axis_user_int[A_USER_WIDTH * ii +: A_USER_WIDTH]),
        .m_axis_out_tready(m_axis_ready_int[ii])
    );
end

// write logic
if (RATIO_TYPE) begin : big_slave
    for (ii = 0; ii < RATIO; ii = ii + 1) begin
        assign s_axis_valid_int[ii] = s_axis_in_tvalid;
        assign s_axis_tlast_int[ii] = s_axis_in_tlast;
    end
    assign s_axis_data_int = s_axis_in_tdata;
    assign s_axis_user_int = s_axis_in_tuser;
end else begin : small_slave
    initial $display("Error: small slave is not yet implemented!");
    initial $finish();
end

// read logic
if (RATIO_TYPE) begin : small_master
    for (ii = 0; ii < RATIO; ii = ii + 1) begin
        assign m_axis_ready_int[ii] = (m_axis_counter == ii) ? m_axis_out_tready : 1'b0;
    end
    
    // user data is the same for all atomic outputs
    assign user_out_ready = (m_axis_counter == 0) ? m_axis_out_tready : 1'b0;
    
    assign m_axis_out_tdata = m_axis_data_int >> (m_axis_counter * A_WIDTH);
    assign m_axis_out_tvalid = m_axis_valid_int >> m_axis_counter;
    assign m_axis_out_tuser = m_axis_user_int >> (m_axis_counter * A_USER_WIDTH);
end else begin : big_master
    initial $display("Error: big master is not yet implemented!");
    initial $finish();
end

// sequencer
if (RATIO == 1) begin
    initial m_axis_counter = 1'b0;
end else begin
    always @(posedge out_clk_i) begin
        if (!m_reset_ni) begin
            m_axis_counter <= 0;
        end else begin
            if (m_axis_out_tready && m_axis_out_tvalid) begin
                m_axis_counter <= m_axis_counter + 1'b1;
            end
        end
    end
end

endmodule
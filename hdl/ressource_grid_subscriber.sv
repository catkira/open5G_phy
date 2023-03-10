// This core receives ressource grid data and provides it to the 
// AXI ring writer via a FIFO with AXI stream interface.
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

module ressource_grid_subscriber #(
    parameter NUM_SEGMENTS = 10,
    parameter SEGMENT_SIZE = 240,
    parameter IQ_WIDTH = 16,

    localparam BRAM_SIZE = NUM_SEGMENTS * SEGMENT_SIZE,
    localparam SFN_MAX = 1023,    
    localparam SUBFRAMES_PER_FRAME = 20,
    localparam SYM_PER_SF = 14,
    localparam SFN_WIDTH = $clog2(SFN_MAX),
    localparam SUBFRAME_NUMBER_WIDTH = $clog2(SUBFRAMES_PER_FRAME - 1),
    localparam SYMBOL_NUMBER_WIDTH = $clog2(SYM_PER_SF - 1),    
    localparam USER_WIDTH = SFN_WIDTH + SUBFRAME_NUMBER_WIDTH + SYMBOL_NUMBER_WIDTH + 1
)
(
    input                                               clk_i,
    input                                               reset_ni,

    // interface to FFT_demod
    input           [IQ_WIDTH - 1 : 0]                  s_axis_iq_tdata,
    input                                               s_axis_iq_tvalid,
    input           [USER_WIDTH - 1 : 0]                s_axis_iq_tuser,
    input                                               s_axis_iq_tlast,

    // interface to AXI ring writer
    input                                               s_axis_fifo_tready,
    output  reg                                         s_axis_fifo_tvalid,
    output  reg     [IQ_WIDTH - 1 : 0]                  s_axis_fifo_tdata,

    input           [$clog2(NUM_SEGMENTS) - 1 : 0]      last_segment_i,
    input                                               busy_i,
    input                                               underflow_i,

    // interface to CPU interrupt controller
    output  reg                                         int_o
);

endmodule
// This core reads data from an AXI stream and writes it into a segmented
// ring buffer. It is assumed that the stream sources delivers data immediately
// after tready goes high, if not this DMA core will stop and signal an underflow.
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

module axi_ring_writer #(
    parameter NUM_SEGMENTS = 10,
    parameter SEGMENT_SIZE = 240,
    parameter IQ_WIDTH = 16,

    localparam BRAM_SIZE = NUM_SEGMENTS * SEGMENT_SIZE    
)
(
    input                                               clk_i,
    input                                               reset_ni,

    // interface to ressource grid subscriber
    output  reg                                         s_axis_fifo_tready,
    input                                               s_axis_fifo_tvalid,
    input           [IQ_WIDTH - 1 : 0]                  s_axis_fifo_tdata,

    output  reg     [$clog2(NUM_SEGMENTS) - 1 : 0]      last_segment_o,
    output  reg                                         busy_o,
    output  reg                                         underflow_o,

    // interface to CPU DMA
);

endmodule
// This core receives ressource grid data and provides it to the 
// AXI-DMAC via AXI stream interface. The block exponent is inserted
// at the beginning of each symbol.
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
    parameter IQ_WIDTH = 16,
    parameter BLK_EXP_LEN = 8,

    localparam SFN_MAX = 1023,    
    localparam SUBFRAMES_PER_FRAME = 20,
    localparam SYM_PER_SF = 14,
    localparam SFN_WIDTH = $clog2(SFN_MAX),
    localparam SUBFRAME_NUMBER_WIDTH = $clog2(SUBFRAMES_PER_FRAME - 1),
    localparam SYMBOL_NUMBER_WIDTH = $clog2(SYM_PER_SF - 1),
    localparam SAMPLE_ID_WIDTH = 64,
    localparam USER_WIDTH =  SFN_WIDTH + SUBFRAME_NUMBER_WIDTH + SYMBOL_NUMBER_WIDTH + BLK_EXP_LEN + 1
)
(
    input                                               clk_i,
    input                                               reset_ni,

    // interface to FFT_demod
    input           [IQ_WIDTH - 1 : 0]                  s_axis_iq_tdata,
    input                                               s_axis_iq_tvalid,
    input           [USER_WIDTH - 1 : 0]                s_axis_iq_tuser,
    input                                               s_axis_iq_tlast,

    // interface to sample_id FIFO
    input           [SAMPLE_ID_WIDTH - 1 : 0]           sample_id_data,
    input                                               sample_id_valid,
    output  reg                                         sample_id_ready,

    // interface to frame_sync
    output  reg                                         overflow_o,

    // interface to AXI-DMAC
    input                                               m_axis_fifo_tready,
    output  reg                                         m_axis_fifo_tvalid,
    output  reg     [IQ_WIDTH - 1 : 0]                  m_axis_fifo_tdata,
    output  reg                                         m_axis_fifo_tlast,

    // interface to CPU interrupt controller
    output  reg                                         int_o
);

reg out_fifo_ready;
wire [IQ_WIDTH - 1 : 0] out_fifo_data;
wire out_fifo_last;
wire out_fifo_valid;
wire [BLK_EXP_LEN - 1 : 0] blk_exp;
AXIS_FIFO #(
    .DATA_WIDTH(IQ_WIDTH),
    .FIFO_LEN(1024),
    .USER_WIDTH(BLK_EXP_LEN),
    .ASYNC(0)
)
output_fifo_i(
    .clk_i(clk_i),
    .s_reset_ni(reset_ni),

    .s_axis_in_tdata(s_axis_iq_tdata),
    .s_axis_in_tvalid(s_axis_iq_tvalid),
    .s_axis_in_tlast(s_axis_iq_tlast),
    .s_axis_in_tuser(s_axis_iq_tuser[BLK_EXP_LEN -: BLK_EXP_LEN]),

    .out_clk_i(clk_i),
    .m_reset_ni(reset_ni),
    .m_axis_out_tready(out_fifo_ready),
    .m_axis_out_tdata(out_fifo_data),
    .m_axis_out_tlast(out_fifo_last),
    .m_axis_out_tuser(blk_exp),
    .m_axis_out_tvalid(out_fifo_valid)
);

always @(posedge clk_i) begin
    if (!reset_ni)  overflow_o <= '0;
    else            overflow_o <= !m_axis_fifo_tready && m_axis_fifo_tvalid;
end

reg [2 : 0] state;
wire [SYMBOL_NUMBER_WIDTH - 1 : 0] symbol_id = s_axis_iq_tuser[SYMBOL_NUMBER_WIDTH + BLK_EXP_LEN + 1 - 1 -: SYMBOL_NUMBER_WIDTH];
wire [SUBFRAME_NUMBER_WIDTH - 1 : 0] subframe_id = s_axis_iq_tuser[SUBFRAME_NUMBER_WIDTH + SYMBOL_NUMBER_WIDTH + BLK_EXP_LEN + 1 - 1 -: SUBFRAME_NUMBER_WIDTH];
wire [SFN_WIDTH - 1 : 0] sfn = s_axis_iq_tuser[USER_WIDTH - 1 -: SFN_WIDTH];
reg [IQ_WIDTH - 1 : 0] sample_buffer;
reg [SAMPLE_ID_WIDTH - 1 : 0] sample_id_buffer;
localparam NUM_TIMESTAMP_SAMPLES = 64 / IQ_WIDTH;
reg [$clog2(NUM_TIMESTAMP_SAMPLES) - 1 : 0] timestamp_cnt;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        state <= '0;
        m_axis_fifo_tdata <= '0;
        m_axis_fifo_tvalid <= '0;
        m_axis_fifo_tlast <= '0;
        sample_buffer <= '0;
        sample_id_ready <= '0;
        timestamp_cnt <= '0;
        out_fifo_ready <= '0;
    end else begin
        case (state)
            0 : begin
                m_axis_fifo_tlast <= '0;
                if (out_fifo_valid) begin
                    // start outputting data when out_fifo has data
                    // output blk_exp first
                    m_axis_fifo_tdata <= blk_exp;
                    m_axis_fifo_tvalid <= 1;
                    state <= 1;
                end else begin
                    m_axis_fifo_tvalid <= '0;
                end
            end
            1 : begin // output timestamp
                if (sample_id_valid) begin
                    m_axis_fifo_tdata <= sample_id_data;
                    sample_id_buffer <= sample_id_data;
                    timestamp_cnt <= 1;
                    m_axis_fifo_tvalid <= 1;
                    sample_id_ready <= 1;
                    state <= 2;
                end else begin
                    m_axis_fifo_tvalid <= '0;
                end
            end
            2: begin // output remaining samples with timestamp
                sample_id_ready <= '0;
                m_axis_fifo_tdata <= sample_id_buffer;
                sample_id_buffer <= sample_id_buffer >> IQ_WIDTH;
                m_axis_fifo_tvalid <= 1;
                if (timestamp_cnt == NUM_TIMESTAMP_SAMPLES - 1) begin
                    out_fifo_ready <= 1;
                    state <= 3;
                end else begin
                    timestamp_cnt <= timestamp_cnt + 1;
                end
            end
            3 : begin // output IQ samples (forward from FIFO)
                m_axis_fifo_tdata <= out_fifo_data;
                m_axis_fifo_tvalid <= out_fifo_valid;
                if (out_fifo_last) begin
                    state <= 0;
                    out_fifo_ready <= '0;
                    m_axis_fifo_tlast <= 1;
                end
            end
        endcase
    end
end

endmodule
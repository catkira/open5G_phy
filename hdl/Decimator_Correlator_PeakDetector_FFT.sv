`timescale 1ns / 1ns

module Decimator_Correlator_PeakDetector_FFT
#(
    parameter IN_DW = 32,           // input data width
    parameter OUT_DW = 32,          // correlator output data width
    parameter TAP_DW = 32,
    parameter PSS_LEN = 128,
    parameter [TAP_DW * PSS_LEN - 1 : 0] PSS_LOCAL_0 = {(PSS_LEN * TAP_DW){1'b0}},
    parameter [TAP_DW * PSS_LEN - 1 : 0] PSS_LOCAL_1 = {(PSS_LEN * TAP_DW){1'b0}},
    parameter [TAP_DW * PSS_LEN - 1 : 0] PSS_LOCAL_2 = {(PSS_LEN * TAP_DW){1'b0}},
    parameter ALGO = 1,
    parameter WINDOW_LEN = 8,
    parameter HALF_CP_ADVANCE = 1,
    parameter NFFT = 8,
    parameter USE_TAP_FILE = 1,
    parameter TAP_FILE = "",
    parameter MULT_REUSE = 0,
    parameter MULT_REUSE_FFT = 1,
    parameter INITIAL_DETECTION_SHIFT = 4,

    localparam FFT_OUT_DW = 32,
    localparam FFT_LEN = 2 ** NFFT,
    localparam CIC_RATE = FFT_LEN / 128,
    localparam MAX_CP_LEN = 20 * FFT_LEN / 256,
    localparam SFN_MAX = 1023,
    localparam SUBFRAMES_PER_FRAME = 20,
    localparam SYM_PER_SF = 14,
    localparam SFN_WIDTH = $clog2(SFN_MAX),
    localparam SUBFRAME_NUMBER_WIDTH = $clog2(SUBFRAMES_PER_FRAME - 1),
    localparam SYMBOL_NUMBER_WIDTH = $clog2(SYM_PER_SF - 1),
    localparam BLK_EXP_LEN = 8,
    localparam OUT_USER_WIDTH = SFN_WIDTH + SUBFRAME_NUMBER_WIDTH + SYMBOL_NUMBER_WIDTH + BLK_EXP_LEN + 1
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire           [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,

    output                                      PBCH_valid_o,
    output                                      SSS_valid_o,
    output                 [FFT_OUT_DW-1:0]     m_axis_out_tdata,
    output                                      m_axis_out_tvalid,
    output                                      m_axis_out_tlast,
    output                 [OUT_USER_WIDTH-1:0] m_axis_out_tuser,
    
    // debug outputs
    output  reg                                 peak_detected_debug_o,
    output  wire            [FFT_OUT_DW-1:0]    fft_result_debug_o,
    output  wire                                fft_sync_debug_o,
    output  wire            [15:0]              sync_wait_counter_debug_o,
    output  reg                                 fft_demod_PBCH_start_o,
    output  reg                                 fft_demod_SSS_start_o,
    output  reg                                 fft_demod_tlast_o,
    output                  [IN_DW-1:0]         m_axis_PSS_out_tdata,
    output                                      m_axis_PSS_out_tvalid
);

wire [IN_DW - 1 : 0] in_data;
wire in_valid;
PSS_detector #(
    .IN_DW(IN_DW),
    .OUT_DW(OUT_DW),
    .TAP_DW(TAP_DW),
    .PSS_LEN(PSS_LEN),
    .PSS_LOCAL_0(PSS_LOCAL_0),
    .PSS_LOCAL_1(PSS_LOCAL_1),
    .PSS_LOCAL_2(PSS_LOCAL_2),
    .ALGO(ALGO),
    .USE_TAP_FILE(USE_TAP_FILE),
    .MULT_REUSE(MULT_REUSE),
    .MULT_REUSE_FFT(MULT_REUSE_FFT),
    .INITIAL_DETECTION_SHIFT(INITIAL_DETECTION_SHIFT),
    .CIC_RATE(CIC_RATE)
)
PSS_detector_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .clear_ni(1'b1),
    .s_axis_in_tdata(s_axis_in_tdata),
    .s_axis_in_tvalid(s_axis_in_tvalid),

    .m_axis_out_tdata(in_data),
    .m_axis_out_tvalid(in_valid),
    .N_id_2_valid_o(peak_detected)
);

wire peak_detected;
assign peak_detected_debug_o = peak_detected;
assign m_axis_PSS_out_tdata = in_data;
assign m_axis_PSS_out_tvalid = in_valid;

wire [FFT_OUT_DW - 1 : 0] fft_result, fft_result_demod;
wire [FFT_OUT_DW / 2 - 1 : 0] fft_result_re, fft_result_im;
wire fft_result_demod_valid;
wire fft_sync;

assign fft_result_debug_o = fft_result;
assign fft_sync_debug_o = fft_sync;

localparam USER_WIDTH = SFN_WIDTH + SUBFRAME_NUMBER_WIDTH + SYMBOL_NUMBER_WIDTH + $clog2(MAX_CP_LEN);

reg [IN_DW - 1 : 0]     fs_out_tdata;
reg [USER_WIDTH - 1 : 0] fs_out_tuser;
reg fs_out_tvalid;
reg fs_out_SSB_start;
wire fs_out_tlast;

frame_sync #(
    .IN_DW(IN_DW),
    .NFFT(NFFT)
)
frame_sync_i
(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .N_id_2_i(),
    .N_id_2_valid_i(peak_detected),
    .ibar_SSB_i(),
    .ibar_SSB_valid_i(),
    .s_axis_in_tdata(in_data),
    .s_axis_in_tvalid(in_valid),

    .PSS_detector_mode_o(),
    .requested_N_id_2_o(),

    .m_axis_out_tdata(fs_out_tdata),
    .m_axis_out_tuser(fs_out_tuser),
    .m_axis_out_tlast(fs_out_tlast),
    .m_axis_out_tvalid(fs_out_tvalid),
    .SSB_start_o(fs_out_SSB_start)
);

localparam FFT_DEMOD_OUT_USER_WIDTH = SFN_WIDTH + SUBFRAME_NUMBER_WIDTH + SYMBOL_NUMBER_WIDTH + BLK_EXP_LEN;
wire [FFT_OUT_DW - 1 : 0] fft_demod_out_tdata;
wire [FFT_DEMOD_OUT_USER_WIDTH - 1 : 0] fft_demod_out_tuser;
wire fft_demod_out_tvalid;
wire fft_demod_out_tlast;
FFT_demod #(
    .IN_DW(IN_DW),
    .OUT_DW(FFT_OUT_DW),
    .HALF_CP_ADVANCE(HALF_CP_ADVANCE),
    .NFFT(NFFT),
    .USE_TAP_FILE(USE_TAP_FILE),
    .TAP_FILE(TAP_FILE)
)
FFT_demod_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .SSB_start_i(fs_out_SSB_start),
    .s_axis_in_tdata(fs_out_tdata),
    .s_axis_in_tlast(fs_out_tlast),
    .s_axis_in_tuser(fs_out_tuser),
    .s_axis_in_tvalid(fs_out_tvalid),
    .m_axis_out_tdata(fft_demod_out_tdata),
    .m_axis_out_tuser(fft_demod_out_tuser),
    .m_axis_out_tlast(fft_demod_out_tlast),
    .m_axis_out_tvalid(fft_demod_out_tvalid)
);

BWP_extractor #(
    .IN_DW(FFT_OUT_DW),
    .NFFT(NFFT),
    .BLK_EXP_LEN(BLK_EXP_LEN)
)
BWP_extractor_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),

    .s_axis_in_tdata(fft_demod_out_tdata),
    .s_axis_in_tuser(fft_demod_out_tuser),
    .s_axis_in_tvalid(fft_demod_out_tvalid),
    .s_axis_in_tlast(fft_demod_out_tlast),

    .m_axis_out_tdata(m_axis_out_tdata),
    .m_axis_out_tuser(m_axis_out_tuser),
    .m_axis_out_tvalid(m_axis_out_tvalid),
    .m_axis_out_tlast(m_axis_out_tlast),
    .PBCH_valid_o(PBCH_valid_o),
    .SSS_valid_o(SSS_valid_o)
);

endmodule


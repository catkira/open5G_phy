`timescale 1ns / 1ns

module Decimator_Correlator_PeakDetector_FFT
#(
    parameter IN_DW = 32,           // input data width
    parameter OUT_DW = 32,          // correlator output data width
    parameter TAP_DW = 32,
    parameter PSS_LEN = 128,
    parameter [TAP_DW * PSS_LEN - 1 : 0] PSS_LOCAL = {(PSS_LEN * TAP_DW){1'b0}},
    parameter ALGO = 1,
    parameter WINDOW_LEN = 8,
    localparam FFT_OUT_DW = 32
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
    
    // debug outputs
    output  wire            [IN_DW-1:0]         m_axis_cic_debug_tdata,
    output  wire                                m_axis_cic_debug_tvalid,
    output  wire            [OUT_DW - 1 : 0]    m_axis_correlator_debug_tdata,
    output  wire                                m_axis_correlator_debug_tvalid,
    output  reg                                 peak_detected_debug_o,
    output  wire            [FFT_OUT_DW-1:0]    fft_result_debug_o,
    output  wire                                fft_sync_debug_o,
    output  wire            [15:0]              sync_wait_counter_debug_o,
    output  reg                                 fft_demod_PBCH_start_o,
    output  reg                                 fft_demod_SSS_start_o
);

wire [IN_DW - 1 : 0] m_axis_cic_tdata;
wire                 m_axis_cic_tvalid;
assign m_axis_cic_debug_tdata = m_axis_cic_tdata;
assign m_axis_cic_debug_tvalid = m_axis_cic_tvalid;

cic_d #(
    .INP_DW(IN_DW/2),
    .OUT_DW(IN_DW/2),
    .CIC_R(2),
    .CIC_N(3),
    .VAR_RATE(0)
)
cic_real(
    .clk(clk_i),
    .reset_n(reset_ni),
    .s_axis_in_tdata(s_axis_in_tdata[IN_DW / 2 - 1 -: IN_DW / 2]),
    .s_axis_in_tvalid(s_axis_in_tvalid),
    .m_axis_out_tdata(m_axis_cic_tdata[IN_DW / 2 - 1 -: IN_DW / 2]),
    .m_axis_out_tvalid(m_axis_cic_tvalid)
);

cic_d #(
    .INP_DW(IN_DW / 2),
    .OUT_DW(IN_DW / 2),
    .CIC_R(2),
    .CIC_N(3),
    .VAR_RATE(0)
)
cic_imag(
    .clk(clk_i),
    .reset_n(reset_ni),
    .s_axis_in_tdata(s_axis_in_tdata[IN_DW - 1 -: IN_DW / 2]),
    .s_axis_in_tvalid(s_axis_in_tvalid),
    .m_axis_out_tdata(m_axis_cic_tdata[IN_DW - 1 -: IN_DW / 2])
);


wire [OUT_DW - 1 : 0] correlator_tdata;
wire correlator_tvalid;
assign m_axis_correlator_debug_tdata = correlator_tdata;
assign m_axis_correlator_debug_tvalid = correlator_tvalid;

PSS_correlator #(
    .IN_DW(IN_DW),
    .OUT_DW(OUT_DW),
    .TAP_DW(TAP_DW),
    .PSS_LEN(PSS_LEN),
    .PSS_LOCAL(PSS_LOCAL),
    .ALGO(ALGO)
)
correlator_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .s_axis_in_tdata(m_axis_cic_tdata),
    .s_axis_in_tvalid(m_axis_cic_tvalid),
    .m_axis_out_tdata(correlator_tdata),
    .m_axis_out_tvalid(correlator_tvalid)
);

wire peak_detected;
assign peak_detected_debug_o = peak_detected;

Peak_detector #(
    .IN_DW(OUT_DW),
    .WINDOW_LEN(WINDOW_LEN)
)
peak_detector_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .s_axis_in_tdata(correlator_tdata),
    .s_axis_in_tvalid(correlator_tvalid),
    .peak_detected_o(peak_detected)
);

wire [FFT_OUT_DW - 1 : 0] fft_result, fft_result_demod;
wire [FFT_OUT_DW / 2 - 1 : 0] fft_result_re, fft_result_im;
wire fft_result_demod_valid;
wire fft_sync;

assign fft_result_debug_o = fft_result;
assign fft_sync_debug_o = fft_sync;

// this delay line is needed because peak_detected goes high
// at the end of SSS symbol plus some additional delay
localparam DELAY_LINE_LEN = 15;
reg [IN_DW-1:0] delay_line_data  [0 : DELAY_LINE_LEN - 1];
reg             delay_line_valid [0 : DELAY_LINE_LEN - 1];
always @(posedge clk_i) begin
    if (!reset_ni) begin
        for (integer i = 0; i < DELAY_LINE_LEN; i = i + 1) begin
            delay_line_data[i] = '0;
            delay_line_valid[i] = '0;
        end
    end else begin
        delay_line_data[0] <= s_axis_in_tdata;
        delay_line_valid[0] <= s_axis_in_tvalid;
        for (integer i = 0; i < DELAY_LINE_LEN - 1; i = i + 1) begin
            delay_line_data[i+1] <= delay_line_data[i];
            delay_line_valid[i+1] <= delay_line_valid[i];
        end
    end
end

FFT_demod #(
    .IN_DW(IN_DW)
)
FFT_demod_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .SSB_start_i(peak_detected),
    .s_axis_in_tdata(delay_line_data[DELAY_LINE_LEN-1]),
    .s_axis_in_tvalid(delay_line_valid[DELAY_LINE_LEN-1]),

    .m_axis_out_tdata(m_axis_out_tdata),
    .m_axis_out_tvalid(m_axis_out_tvalid),
    .PBCH_start_o(fft_demod_PBCH_start_o),
    .SSS_start_o(fft_demod_SSS_start_o),
    .PBCH_valid_o(PBCH_valid_o),
    .SSS_valid_o(SSS_valid_o)
);

`ifdef COCOTB_SIM
initial begin
  $dumpfile ("debug.vcd");
  $dumpvars (0, Decimator_Correlator_PeakDetector_FFT);
end
`endif

endmodule


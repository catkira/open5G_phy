`timescale 1ns / 1ns

`ifdef VERILATOR  // make parameter readable from VPI
  `define VL_RD /*verilator public_flat_rd*/
`else
  `define VL_RD
`endif

module receiver
#(
    parameter IN_DW `VL_RD = 32,           // input data width
    parameter OUT_DW `VL_RD = 32,          // correlator output data width
    parameter TAP_DW `VL_RD = 32,
    parameter PSS_LEN `VL_RD = 128,
    parameter [TAP_DW * PSS_LEN - 1 : 0] PSS_LOCAL_0 `VL_RD = {(PSS_LEN * TAP_DW){1'b0}},
    parameter [TAP_DW * PSS_LEN - 1 : 0] PSS_LOCAL_1 `VL_RD = {(PSS_LEN * TAP_DW){1'b0}},
    parameter [TAP_DW * PSS_LEN - 1 : 0] PSS_LOCAL_2 `VL_RD = {(PSS_LEN * TAP_DW){1'b0}},
    parameter ALGO `VL_RD = 1,
    parameter WINDOW_LEN `VL_RD = 8,
    parameter CP_ADVANCE `VL_RD = 9,
    parameter USE_TAP_FILE = 0,
    parameter TAP_FILE_0 = "",
    parameter TAP_FILE_1 = "",
    parameter TAP_FILE_2 = "",

    localparam FFT_OUT_DW `VL_RD = 32,
    localparam N_id_1_MAX `VL_RD = 335,
    localparam DDS_PHASE_DW = 20,
    localparam DDS_OUT_DW = 32,
    localparam CFO_DW = 20,
    localparam COMPL_MULT_OUT_DW = 32
)
(
    input                                           clk_i,
    input                                           reset_ni,

    input                                           sample_clk_i,
    input   wire    [IN_DW-1:0]                     s_axis_in_tdata,
    input                                           s_axis_in_tvalid,

    output                                          PBCH_valid_o,
    output                                          SSS_valid_o,
    output          [FFT_OUT_DW-1:0]                m_axis_cest_out_tdata,
    output          [1 : 0]                         m_axis_cest_out_tuser,
    output                                          m_axis_cest_out_tvalid,
    output          [FFT_OUT_DW-1:0]                m_axis_demod_out_tdata,
    output                                          m_axis_demod_out_tvalid,
    output          [$clog2(N_id_1_MAX) - 1 : 0]    m_axis_SSS_tdata,
    output                                          m_axis_SSS_tvalid,
    
    // debug outputs
    output  wire    [IN_DW-1:0]                     m_axis_cic_debug_tdata,
    output  wire                                    m_axis_cic_debug_tvalid,
    output  wire    [OUT_DW - 1 : 0]                m_axis_correlator_debug_tdata,
    output  wire                                    m_axis_correlator_debug_tvalid,
    output  reg                                     peak_detected_debug_o,
    output  wire    [FFT_OUT_DW-1:0]                fft_result_debug_o,
    output  wire                                    fft_sync_debug_o,
    output  wire    [15:0]                          sync_wait_counter_debug_o,
    output  reg                                     fft_demod_PBCH_start_o,
    output  reg                                     fft_demod_SSS_start_o
);

wire [IN_DW - 1 : 0] m_axis_cic_tdata;
wire                 m_axis_cic_tvalid;
assign m_axis_cic_debug_tdata = m_axis_cic_tdata;
assign m_axis_cic_debug_tvalid = m_axis_cic_tvalid;


reg [COMPL_MULT_OUT_DW - 1 : 0] mult_out_tdata;
reg                             mult_out_tvalid;

reg [IN_DW - 1 : 0]             FIFO_out_tdata;
reg                             FIFO_out_tvalid;

AXIS_FIFO #(
    .DATA_WIDTH(IN_DW),
    .FIFO_LEN(16),
    .ASYNC(1)
)
AXIS_FIFO_i(
    .clk_i(sample_clk_i),
    .reset_ni(reset_ni),

    .s_axis_in_tdata(s_axis_in_tdata),
    .s_axis_in_tvalid(s_axis_in_tvalid),

    .out_clk_i(clk_i),
    .m_axis_out_tready(1'b1),
    .m_axis_out_tdata(FIFO_out_tdata),
    .m_axis_out_tvalid(FIFO_out_tvalid)
);


reg signed [DDS_PHASE_DW - 1 : 0]   CFO_DDS_inc, CFO_DDS_inc_f;
reg                                 CFO_valid;
wire [DDS_OUT_DW - 1 : 0]           DDS_out;
wire DDS_out_valid;
reg [DDS_PHASE_DW - 1 : 0]          DDS_phase;
reg                                 DDS_phase_valid;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        DDS_phase <= '0;
        DDS_phase_valid <= '0;
        CFO_DDS_inc_f <= '0;
    end 
    else begin
        if (CFO_valid) begin
            // CFO_DDS_inc_f <= '0; // deactive CFO correction for now
            CFO_DDS_inc_f <= CFO_DDS_inc_f - CFO_DDS_inc;  // incoming CFO_DDS_inc are relative to last one !
        end
        if(s_axis_in_tvalid) begin
            DDS_phase <= DDS_phase + CFO_DDS_inc_f;
            DDS_phase_valid <= 1;
        end
    end
end

dds #(
    .PHASE_DW(DDS_PHASE_DW),
    .OUT_DW(DDS_OUT_DW/2),
    .USE_TAYLOR(1),
    .LUT_DW(16),
    .SIN_COS(1),
    .NEGATIVE_SINE(0),
    .NEGATIVE_COSINE(0)
)
dds_i(
    .clk(clk_i),
    .reset_n(reset_ni),

    .s_axis_phase_tdata(DDS_phase),
    .s_axis_phase_tvalid(DDS_phase_valid),

    .m_axis_out_tdata(DDS_out),
    .m_axis_out_tvalid(DDS_out_valid)
);

complex_multiplier #(
    .OPERAND_WIDTH_A(DDS_OUT_DW/2),
    .OPERAND_WIDTH_B(IN_DW/2),
    .OPERAND_WIDTH_OUT(COMPL_MULT_OUT_DW/2),
    .BLOCKING(0),
    .GROWTH_BITS(-2),  // input is rotating vector with length 2^(IN_DW/2 - 1), therefore bit growth is 2 bits less than worst case
    .BYTE_ALIGNED(0)
)
complex_multiplier_i(
    .aclk(clk_i),
    .aresetn(reset_ni),

    .s_axis_a_tdata(DDS_out),
    .s_axis_a_tvalid(DDS_out_valid),
    .s_axis_b_tdata(FIFO_out_tdata),
    .s_axis_b_tvalid(FIFO_out_tvalid),

    .m_axis_dout_tdata(mult_out_tdata),
    .m_axis_dout_tvalid(mult_out_tvalid)
);

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

    .s_axis_in_tdata(mult_out_tdata[COMPL_MULT_OUT_DW / 2 - 1 -: COMPL_MULT_OUT_DW / 2]),
    .s_axis_in_tvalid(mult_out_tvalid),

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

    .s_axis_in_tdata(mult_out_tdata[COMPL_MULT_OUT_DW - 1 -: COMPL_MULT_OUT_DW / 2]),
    .s_axis_in_tvalid(mult_out_tvalid),

    .m_axis_out_tdata(m_axis_cic_tdata[IN_DW - 1 -: IN_DW / 2]),
    .m_axis_out_tvalid()
);


wire [OUT_DW - 1 : 0] correlator_tdata;
wire correlator_tvalid;
assign m_axis_correlator_debug_tdata = correlator_tdata;
assign m_axis_correlator_debug_tvalid = correlator_tvalid;

reg N_id_2_valid;
wire [1 : 0] N_id_2;
wire [1 : 0] PSS_detector_mode;
wire [1 : 0] requested_N_id_2;

PSS_detector #(
    .IN_DW(IN_DW),
    .OUT_DW(OUT_DW),
    .TAP_DW(TAP_DW),
    .CFO_DW(CFO_DW),
    .DDS_DW(DDS_PHASE_DW),
    .PSS_LEN(PSS_LEN),
    .PSS_LOCAL_0(PSS_LOCAL_0),
    .PSS_LOCAL_1(PSS_LOCAL_1),
    .PSS_LOCAL_2(PSS_LOCAL_2),
    .ALGO(ALGO),
    .USE_MODE(1),
    .USE_TAP_FILE(USE_TAP_FILE),
    .TAP_FILE_0(TAP_FILE_0),
    .TAP_FILE_1(TAP_FILE_1),
    .TAP_FILE_2(TAP_FILE_2)
)
PSS_detector_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),

    .s_axis_in_tdata(m_axis_cic_tdata),
    .s_axis_in_tvalid(m_axis_cic_tvalid),
    .mode_i(PSS_detector_mode),
    .requested_N_id_2_i(requested_N_id_2),

    .N_id_2_valid_o(N_id_2_valid),
    .N_id_2_o(N_id_2),
    .CFO_DDS_inc_o(CFO_DDS_inc),
    .CFO_angle_o(),
    .CFO_valid_o(CFO_valid)
);

assign peak_detected_debug_o = N_id_2_valid;

wire [FFT_OUT_DW - 1 : 0] fft_result, fft_result_demod;
wire [FFT_OUT_DW / 2 - 1 : 0] fft_result_re, fft_result_im;
wire fft_result_demod_valid;
wire fft_sync;

assign fft_result_debug_o = fft_result;
assign fft_sync_debug_o = fft_sync;

// this delay line is needed because peak_detected goes high
// at the end of SSS symbol plus some additional delay
localparam DELAY_LINE_LEN = 16;
reg [IN_DW-1:0] delay_line_data  [0 : DELAY_LINE_LEN - 1];
reg             delay_line_valid [0 : DELAY_LINE_LEN - 1];
always @(posedge clk_i) begin
    if (!reset_ni) begin
        for (integer i = 0; i < DELAY_LINE_LEN; i = i + 1) begin
            delay_line_data[i] = '0;
            delay_line_valid[i] = '0;
        end
    end else begin
        delay_line_data[0] <= mult_out_tdata;
        delay_line_valid[0] <= mult_out_tvalid;
        // delay_line_data[0] <= s_axis_in_tdata;
        // delay_line_valid[0] <= s_axis_in_tvalid;
        for (integer i = 0; i < DELAY_LINE_LEN - 1; i = i + 1) begin
            delay_line_data[i+1] <= delay_line_data[i];
            delay_line_valid[i+1] <= delay_line_valid[i];
        end
    end
end

reg [IN_DW - 1 : 0]     fs_out_tdata;
reg fs_out_tvalid;
reg fs_out_PBCH_start;
reg fs_out_symbol_start;
reg fs_out_SSS_start;


frame_sync #(
    .IN_DW(IN_DW)
)
frame_sync_i
(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .N_id_2_i(N_id_2),
    .N_id_2_valid_i(N_id_2_valid),
    .ibar_SSB_i(ce_ibar_SSB),
    .ibar_SSB_valid_i(ce_ibar_SSB_valid),
    .s_axis_in_tdata(delay_line_data[DELAY_LINE_LEN - 1]),
    .s_axis_in_tvalid(delay_line_valid[DELAY_LINE_LEN - 1]),

    .PSS_detector_mode_o(PSS_detector_mode),
    .requested_N_id_2_o(requested_N_id_2),

    .m_axis_out_tdata(fs_out_tdata),
    .m_axis_out_tvalid(fs_out_tvalid),
    .symbol_start_o(fs_out_symbol_start),
    .PBCH_start_o(fs_out_PBCH_start),
    .SSS_start_o(fs_out_SSS_start)
);

wire [FFT_OUT_DW - 1 : 0] fft_demod_out_tdata;
wire                      fft_demod_out_tvalid;
assign m_axis_demod_out_tdata = fft_demod_out_tdata;
assign m_axis_demod_out_tvalid = fft_demod_out_tvalid;
FFT_demod #(
    .IN_DW(IN_DW),
    .CP_ADVANCE(CP_ADVANCE)
)
FFT_demod_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .SSB_start_i(fs_out_PBCH_start),
    .s_axis_in_tdata(fs_out_tdata),
    .s_axis_in_tvalid(fs_out_tvalid),
    .m_axis_out_tdata(fft_demod_out_tdata),
    .m_axis_out_tvalid(fft_demod_out_tvalid),
    .PBCH_start_o(fft_demod_PBCH_start_o),
    .SSS_start_o(fft_demod_SSS_start_o),
    .PBCH_valid_o(PBCH_valid_o),
    .SSS_valid_o(SSS_valid_o)
);

reg [10 : 0] PSS_cnt;

SSS_detector
SSS_detector_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .N_id_2_i(N_id_2),
    .N_id_2_valid_i(N_id_2_valid),
    .s_axis_in_tdata(~fft_demod_out_tdata[FFT_OUT_DW / 2 - 1]), // BPSK demod by just taking the MSB of the real part
    .s_axis_in_tvalid(SSS_valid_o),
    .m_axis_out_tdata(m_axis_SSS_tdata),
    .m_axis_out_tvalid(m_axis_SSS_tvalid),
    .N_id_o(N_id),
    .N_id_valid_o(N_id_valid)
);

reg [2 : 0] ce_ibar_SSB;
reg ce_ibar_SSB_valid;

localparam N_ID_MAX = 1007;
reg [$clog2(N_ID_MAX) - 1 : 0] N_id;
reg N_id_valid;

channel_estimator #(
    .IN_DW(IN_DW)
)
channel_estimator_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .N_id_i(N_id),
    .N_id_valid_i(N_id_valid),
    .PBCH_start_i(fft_demod_PBCH_start_o),
    .s_axis_in_tdata(fft_demod_out_tdata),
    .s_axis_in_tvalid(fft_demod_out_tvalid),

    .m_axis_out_tdata(m_axis_cest_out_tdata),
    .m_axis_out_tuser(m_axis_cest_out_tuser),
    .m_axis_out_tvalid(m_axis_cest_out_tvalid),

    .debug_ibar_SSB_o(ce_ibar_SSB),
    .debug_ibar_SSB_valid_o(ce_ibar_SSB_valid)
);

endmodule
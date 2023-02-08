`timescale 1ns / 1ns

module test_CFO_correction
#(
    parameter IN_DW = 32,           // input data width
    parameter OUT_DW = 32,          // correlator output data width
    parameter TAP_DW = 32,
    parameter PSS_LEN = 128,
    parameter [TAP_DW * PSS_LEN - 1 : 0] PSS_LOCAL = {(PSS_LEN * TAP_DW){1'b0}},
    parameter ALGO = 0,
    parameter WINDOW_LEN = 8,
    parameter MULT_REUSE = 16,
    parameter DDS_OUT_DW = 32,
    parameter DDS_PHASE_DW = 20,
    parameter COMPL_MULT_OUT_DW = 32,   // has to be multiple of 16
    parameter CIC_OUT_DW = 34
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire           [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,
    
    output  wire           [CIC_OUT_DW + TAP_DW + 2 + 2 * $clog2(PSS_LEN) - 1 : 0]   C0,
    output  wire           [CIC_OUT_DW + TAP_DW + 2 + 2 * $clog2(PSS_LEN) - 1: 0]    C1,

    output  reg                                 peak_detected_o,
    
    // debug outputs
    output  wire           [CIC_OUT_DW-1:0]     m_axis_cic_debug_tdata,
    output  wire                                m_axis_cic_debug_tvalid,
    output  wire           [OUT_DW - 1 : 0]     m_axis_correlator_debug_tdata,
    output  wire                                m_axis_correlator_debug_tvalid
);



wire [CIC_OUT_DW - 1 : 0]       m_axis_cic_tdata;
wire                            m_axis_cic_tvalid;
assign m_axis_cic_debug_tdata = m_axis_cic_tdata;
assign m_axis_cic_debug_tvalid = m_axis_cic_tvalid;

wire [DDS_OUT_DW - 1 : 0]       DDS_out;
wire DDS_out_valid;

reg [DDS_PHASE_DW - 1 : 0]      DDS_phase;
reg                             DDS_phase_valid;
reg [COMPL_MULT_OUT_DW - 1 : 0] mult_out_tdata;
reg                             mult_out_tvalid;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        DDS_phase <= '0;
        DDS_phase_valid <= '0;
    end else begin
        DDS_phase <= '0;
        DDS_phase_valid <= 1;
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
    .BLOCKING(0)
)
complex_multiplier_i(
    .aclk(clk_i),
    .aresetn(reset_ni),
    .s_axis_a_tdata(DDS_out),
    .s_axis_a_tvalid(DDS_out_valid),
    .s_axis_b_tdata(s_axis_in_tdata),
    .s_axis_b_tvalid(s_axis_in_tvalid),

    .m_axis_dout_tdata(mult_out_tdata),
    .m_axis_dout_tvalid(mult_out_tvalid)
);

cic_d #(
    .INP_DW(COMPL_MULT_OUT_DW/2),
    .OUT_DW(CIC_OUT_DW/2),
    .CIC_R(2),
    .CIC_N(3),
    .VAR_RATE(0)
)
cic_real(
    .clk(clk_i),
    .reset_n(reset_ni),
    .s_axis_in_tdata(mult_out_tdata[COMPL_MULT_OUT_DW / 2 - 1 -: COMPL_MULT_OUT_DW / 2]),
    .s_axis_in_tvalid(mult_out_tvalid),

    .m_axis_out_tdata(m_axis_cic_tdata[CIC_OUT_DW / 2 - 1 -: CIC_OUT_DW / 2]),
    .m_axis_out_tvalid(m_axis_cic_tvalid)
);

cic_d #(
    .INP_DW(COMPL_MULT_OUT_DW / 2),
    .OUT_DW(CIC_OUT_DW / 2),
    .CIC_R(2),
    .CIC_N(3),
    .VAR_RATE(0)
)
cic_imag(
    .clk(clk_i),
    .reset_n(reset_ni),
    .s_axis_in_tdata(mult_out_tdata[COMPL_MULT_OUT_DW - 1 -: COMPL_MULT_OUT_DW / 2]),
    .s_axis_in_tvalid(mult_out_tvalid),

    .m_axis_out_tdata(m_axis_cic_tdata[CIC_OUT_DW - 1 -: CIC_OUT_DW / 2]),
    .m_axis_out_tvalid()  // not used
);


wire [OUT_DW - 1 : 0] correlator_tdata;
wire correlator_tvalid;
assign m_axis_correlator_debug_tdata = correlator_tdata;
assign m_axis_correlator_debug_tvalid = correlator_tvalid;

PSS_correlator_mr #(
    .IN_DW(CIC_OUT_DW),
    .OUT_DW(OUT_DW),
    .TAP_DW(TAP_DW),
    .PSS_LEN(PSS_LEN),
    .PSS_LOCAL(PSS_LOCAL),
    .ALGO(ALGO),
    .MULT_REUSE(MULT_REUSE)
)
correlator(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .s_axis_in_tdata(m_axis_cic_tdata),
    .s_axis_in_tvalid(m_axis_cic_tvalid),
    .m_axis_out_tdata(correlator_tdata),
    .m_axis_out_tvalid(correlator_tvalid),
    .C0(C0),
    .C1(C1)
);

Peak_detector #(
    .IN_DW(OUT_DW),
    .WINDOW_LEN(WINDOW_LEN)
)
peak_detector(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .s_axis_in_tdata(correlator_tdata),
    .s_axis_in_tvalid(correlator_tvalid),
    .peak_detected_o(peak_detected_o)
);

`ifdef COCOTB_SIM
initial begin
  $dumpfile ("debug.vcd");
  $dumpvars (0, test_CFO_correction);
end
`endif

endmodule
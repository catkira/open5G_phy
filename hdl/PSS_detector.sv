`timescale 1ns / 1ns

module PSS_detector
#(
    parameter IN_DW = 32,           // input data width
    parameter OUT_DW = 32,          // correlator output data width
    parameter TAP_DW = 32,
    parameter PSS_LEN = 128,
    parameter [TAP_DW * PSS_LEN - 1 : 0] PSS_LOCAL_0 = {(PSS_LEN * TAP_DW){1'b0}},
    parameter [TAP_DW * PSS_LEN - 1 : 0] PSS_LOCAL_1 = {(PSS_LEN * TAP_DW){1'b0}},
    parameter [TAP_DW * PSS_LEN - 1 : 0] PSS_LOCAL_2 = {(PSS_LEN * TAP_DW){1'b0}},
    parameter USE_TAP_FILE = 0,
    parameter TAP_FILE_0 = "",
    parameter TAP_FILE_1 = "",
    parameter TAP_FILE_2 = "",
    parameter TAP_FILE_PATH = "",
    parameter ALGO = 1,
    parameter WINDOW_LEN = 8,
    parameter USE_MODE = 0,
    parameter CFO_DW = 24,
    parameter DDS_DW = 20,
    parameter MULT_REUSE = 1,
    parameter PEAK_COUNTER = 1,
    parameter VARIABLE_NOISE_LIMIT = 0,
    parameter VARIABLE_DETECTION_FACTOR = 0,
    parameter INITIAL_DETECTION_SHIFT = 3,

    localparam SAMPLE_RATE = 1920000,
    localparam AXI_ADDRESS_WIDTH = 11
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire           [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,

    input                  [1 : 0]              mode_i,
    input                  [1 : 0]              requested_N_id_2_i,
    
    output  reg            [1 : 0]              N_id_2_o,
    output                                      N_id_2_valid_o,
    output  reg signed     [CFO_DW - 1 : 0]     CFO_angle_o,
    output  reg signed     [DDS_DW - 1 : 0]     CFO_DDS_inc_o,
    output  reg                                 CFO_valid_o,
    output                                      CFO_mode_o,

    // AXI lite interface
    // write address channel
    input           [AXI_ADDRESS_WIDTH - 1 : 0] s_axi_awaddr,
    input                                       s_axi_awvalid,
    output  reg                                 s_axi_awready,
    
    // write data channel
    input           [31 : 0]                    s_axi_wdata,
    input           [ 3 : 0]                    s_axi_wstrb,      // not used
    input                                       s_axi_wvalid,
    output  reg                                 s_axi_wready,

    // write response channel
    output          [ 1 : 0]                    s_axi_bresp,
    output  reg                                 s_axi_bvalid,
    input                                       s_axi_bready,

    // read address channel
    input           [AXI_ADDRESS_WIDTH - 1 : 0] s_axi_araddr,
    input                                       s_axi_arvalid,
    output  reg                                 s_axi_arready,

    // read data channel
    output  reg     [31 : 0]                    s_axi_rdata,
    output          [ 1 : 0]                    s_axi_rresp,
    output  reg                                 s_axi_rvalid,
    input                                       s_axi_rready,    
    
    // debug outputs
    output  wire           [IN_DW-1:0]          m_axis_cic_debug_tdata,
    output  wire                                m_axis_cic_debug_tvalid,
    output  wire           [OUT_DW - 1 : 0]     m_axis_correlator_debug_tdata,
    output  wire                                m_axis_correlator_debug_tvalid,
    output                 [TAP_DW - 1 : 0]     taps_2_o [0 : PSS_LEN - 1]
);

localparam C_DW = IN_DW + TAP_DW + 2 + 2 * $clog2(PSS_LEN);  

wire [OUT_DW - 1 : 0] correlator_0_tdata, correlator_1_tdata, correlator_2_tdata;
wire correlator_0_tvalid, correlator_1_tvalid, correlator_2_tvalid;
wire [C_DW - 1 : 0] C0 [0 : 2];
wire [C_DW - 1 : 0] C1 [0 : 2];
assign m_axis_correlator_debug_tdata = correlator_2_tdata;
assign m_axis_correlator_debug_tvalid = correlator_2_tvalid;
reg [2 : 0] peak_detected; 
reg correlator_en;
reg [IN_DW-1:0] score [0 : 2];
wire [OUT_DW - 1 : 0] noise_limit;
wire [7 : 0] detection_shift;
wire cfo_mode;
assign CFO_mode_o = cfo_mode;
localparam CFO_MODE_AUTO = 1'b0;
localparam CFO_MODE_MANUAL = 1'b1;

reg [31 : 0] peak_counter_0;
reg [31 : 0] peak_counter_1;
reg [31 : 0] peak_counter_2;
if (PEAK_COUNTER) begin
    always @(posedge clk_i) begin
        if (!reset_ni) begin
            peak_counter_0 <= '0;
            peak_counter_1 <= '0;
            peak_counter_2 <= '0;
        end else begin
            peak_counter_0 <= peak_detected[0] ? peak_counter_0 + 1 : peak_counter_0;
            peak_counter_1 <= peak_detected[1] ? peak_counter_1 + 1 : peak_counter_1;
            peak_counter_2 <= peak_detected[2] ? peak_counter_2 + 1 : peak_counter_2;
        end
    end
end else begin
    initial peak_counter_0 <= '0;
    initial peak_counter_1 <= '0;
    initial peak_counter_2 <= '0;
end

if (MULT_REUSE == 0) begin
    PSS_correlator #(
        .IN_DW(IN_DW),
        .OUT_DW(OUT_DW),
        .TAP_DW(TAP_DW),
        .PSS_LEN(PSS_LEN),
        .PSS_LOCAL(PSS_LOCAL_0),
        .USE_TAP_FILE(USE_TAP_FILE),
        .TAP_FILE(TAP_FILE_0),
        .TAP_FILE_PATH(TAP_FILE_PATH),
        .ALGO(ALGO),
        .N_ID_2(0)
    )
    correlator_0_i(
        .clk_i(clk_i),
        .reset_ni(reset_ni),
        .s_axis_in_tdata(s_axis_in_tdata),
        .s_axis_in_tvalid(s_axis_in_tvalid && correlator_en),
        .C0_o(C0[0]),
        .C1_o(C1[0]),
        .m_axis_out_tdata(correlator_0_tdata),
        .m_axis_out_tvalid(correlator_0_tvalid)
    );

    PSS_correlator #(
        .IN_DW(IN_DW),
        .OUT_DW(OUT_DW),
        .TAP_DW(TAP_DW),
        .PSS_LEN(PSS_LEN),
        .PSS_LOCAL(PSS_LOCAL_1),
        .USE_TAP_FILE(USE_TAP_FILE),
        .TAP_FILE(TAP_FILE_1),
        .TAP_FILE_PATH(TAP_FILE_PATH),
        .ALGO(ALGO),
        .N_ID_2(1)
    )
    correlator_1_i(
        .clk_i(clk_i),
        .reset_ni(reset_ni),
        .s_axis_in_tdata(s_axis_in_tdata),
        .s_axis_in_tvalid(s_axis_in_tvalid && correlator_en),
        .C0_o(C0[1]),
        .C1_o(C1[1]),
        .m_axis_out_tdata(correlator_1_tdata),
        .m_axis_out_tvalid(correlator_1_tvalid)
    );

    PSS_correlator #(
        .IN_DW(IN_DW),
        .OUT_DW(OUT_DW),
        .TAP_DW(TAP_DW),
        .PSS_LEN(PSS_LEN),
        .PSS_LOCAL(PSS_LOCAL_2),
        .USE_TAP_FILE(USE_TAP_FILE),
        .TAP_FILE(TAP_FILE_2),
        .TAP_FILE_PATH(TAP_FILE_PATH),
        .ALGO(ALGO),
        .N_ID_2(2)
    )
    correlator_2_i(
        .clk_i(clk_i),
        .reset_ni(reset_ni),
        .s_axis_in_tdata(s_axis_in_tdata),
        .s_axis_in_tvalid(s_axis_in_tvalid && correlator_en),
        .C0_o(C0[2]),
        .C1_o(C1[2]),
        .m_axis_out_tdata(correlator_2_tdata),
        .m_axis_out_tvalid(correlator_2_tvalid),
        .taps_o(taps_2_o)
    );
end else begin
    PSS_correlator_mr #(
        .IN_DW(IN_DW),
        .OUT_DW(OUT_DW),
        .TAP_DW(TAP_DW),
        .PSS_LEN(PSS_LEN),
        .PSS_LOCAL(PSS_LOCAL_0),
        .USE_TAP_FILE(USE_TAP_FILE),
        .TAP_FILE(TAP_FILE_0),
        .TAP_FILE_PATH(TAP_FILE_PATH),
        .N_ID_2(0),
        .MULT_REUSE(MULT_REUSE)
    )
    correlator_0_i(
        .clk_i(clk_i),
        .reset_ni(reset_ni),
        .s_axis_in_tdata(s_axis_in_tdata),
        .s_axis_in_tvalid(s_axis_in_tvalid && correlator_en),
        .C0_o(C0[0]),
        .C1_o(C1[0]),
        .m_axis_out_tdata(correlator_0_tdata),
        .m_axis_out_tvalid(correlator_0_tvalid)
    );

    PSS_correlator_mr #(
        .IN_DW(IN_DW),
        .OUT_DW(OUT_DW),
        .TAP_DW(TAP_DW),
        .PSS_LEN(PSS_LEN),
        .PSS_LOCAL(PSS_LOCAL_1),
        .USE_TAP_FILE(USE_TAP_FILE),
        .TAP_FILE(TAP_FILE_1),
        .TAP_FILE_PATH(TAP_FILE_PATH),
        .N_ID_2(1),
        .MULT_REUSE(MULT_REUSE)
    )
    correlator_1_i(
        .clk_i(clk_i),
        .reset_ni(reset_ni),
        .s_axis_in_tdata(s_axis_in_tdata),
        .s_axis_in_tvalid(s_axis_in_tvalid && correlator_en),
        .C0_o(C0[1]),
        .C1_o(C1[1]),
        .m_axis_out_tdata(correlator_1_tdata),
        .m_axis_out_tvalid(correlator_1_tvalid)
    );

    PSS_correlator_mr #(
        .IN_DW(IN_DW),
        .OUT_DW(OUT_DW),
        .TAP_DW(TAP_DW),
        .PSS_LEN(PSS_LEN),
        .PSS_LOCAL(PSS_LOCAL_2),
        .USE_TAP_FILE(USE_TAP_FILE),
        .TAP_FILE(TAP_FILE_2),
        .TAP_FILE_PATH(TAP_FILE_PATH),
        .N_ID_2(2),
        .MULT_REUSE(MULT_REUSE)
    )
    correlator_2_i(
        .clk_i(clk_i),
        .reset_ni(reset_ni),
        .s_axis_in_tdata(s_axis_in_tdata),
        .s_axis_in_tvalid(s_axis_in_tvalid && correlator_en),
        .C0_o(C0[2]),
        .C1_o(C1[2]),
        .m_axis_out_tdata(correlator_2_tdata),
        .m_axis_out_tvalid(correlator_2_tvalid),
        .taps_o(taps_2_o)
    );    
end

Peak_detector #(
    .IN_DW(OUT_DW),
    .WINDOW_LEN(WINDOW_LEN)
)
peak_detector_0_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .s_axis_in_tdata(correlator_0_tdata),
    .s_axis_in_tvalid(correlator_0_tvalid),
    .noise_limit_i(noise_limit),
    .detection_shift_i(detection_shift),
    .peak_detected_o(peak_detected[0]),
    .score_o(score[0])    
);

Peak_detector #(
    .IN_DW(OUT_DW),
    .WINDOW_LEN(WINDOW_LEN)
)
peak_detector_1_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .s_axis_in_tdata(correlator_1_tdata),
    .s_axis_in_tvalid(correlator_1_tvalid),
    .noise_limit_i(noise_limit),
    .detection_shift_i(detection_shift),
    .peak_detected_o(peak_detected[1]),
    .score_o(score[1])
);

Peak_detector #(
    .IN_DW(OUT_DW),
    .WINDOW_LEN(WINDOW_LEN)
)
peak_detector_2_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .s_axis_in_tdata(correlator_2_tdata),
    .s_axis_in_tvalid(correlator_2_tvalid),
    .noise_limit_i(noise_limit),
    .detection_shift_i(detection_shift),
    .peak_detected_o(peak_detected[2]),
    .score_o(score[2])    
);

reg [C_DW - 1 : 0] C0_f [0 : 2];
reg [C_DW - 1 : 0] C1_f [0 : 2];
always @(posedge clk_i) begin
    if (!reset_ni) begin
        C0_f[0] <= '0;
        C0_f[1] <= '0;
        C0_f[2] <= '0;
        C1_f[0] <= '0;
        C1_f[1] <= '0;
        C1_f[2] <= '0;
    end else begin
        C0_f[0] <= C0[0];
        C0_f[1] <= C0[1];
        C0_f[2] <= C0[2];
        C1_f[0] <= C1[0];
        C1_f[1] <= C1[1];
        C1_f[2] <= C1[2];
    end
end


reg [C_DW - 1 : 0] C0_in, C1_in;
reg CFO_calc_valid_in;
reg CFO_calc_valid_out;
reg signed [CFO_DW - 1 : 0] CFO_angle;
reg signed [DDS_DW - 1 : 0] CFO_DDS_inc;
CFO_calc #(
    .C_DW(C_DW),
    .CFO_DW(CFO_DW),
    .DDS_DW(DDS_DW)
)
CFO_calc_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .C0_i(C0_in),
    .C1_i(C1_in),
    .valid_i(CFO_calc_valid_in),

    .CFO_angle_o(CFO_angle),
    .CFO_DDS_inc_o(CFO_DDS_inc),
    .valid_o(CFO_calc_valid_out)
);

localparam [1 : 0]  SEARCH = 0;
localparam [1 : 0]  FIND   = 1;
localparam [1 : 0]  PAUSE  = 2;
localparam SSB_INTERVAL = $rtoi(1920000 * 0.02);
localparam TRACK_TOLERANCE = 100;
localparam CORRELATOR_DELAY = 160;
reg [$clog2(SSB_INTERVAL + TRACK_TOLERANCE) - 1 : 0] sample_cnt;
reg peak_valid;

reg [1 : 0] CFO_state;
localparam [1 : 0] WAIT_FOR_PEAK = 0;
localparam [1 : 0] DISABLE_CFO_IN = 1;
localparam [1 : 0] WAIT_FOR_CFO = 2;

//-------------------------------------------------------------------------------
// FSM to control CFO_calc
// it is not sensitive to new incoming peaks while it waits for CFO_calc to finish
// this can cause a peak to be ignored if it follows close after another peak
// 
// TODO: signal a valid N_id_2 only of the calculated CFO is below a certain threshold,
// i.e. +- 100 Hz, if it is above, wait for next SSB with corrected CFO
always @(posedge clk_i) begin
    if (!reset_ni) begin
        CFO_state <= WAIT_FOR_PEAK;
        CFO_angle_o <= '0;
        CFO_DDS_inc_o <= '0;
        CFO_valid_o <= '0;
    end else begin
        case (CFO_state)
            WAIT_FOR_PEAK : begin
                CFO_valid_o <= '0;
                if (peak_valid) begin
                    C0_in <= C0_f[N_id_2_o];
                    C1_in <= C1_f[N_id_2_o];
                    CFO_calc_valid_in <= 1;
                    CFO_state <= DISABLE_CFO_IN;
                end
            end
            DISABLE_CFO_IN : begin
                CFO_calc_valid_in <= '0;
                CFO_state <= WAIT_FOR_CFO;
            end
            WAIT_FOR_CFO : begin
                if (CFO_calc_valid_out) begin
                    $display("PSS_detector: detected CFO angle is %f deg", $itor(CFO_angle) / $itor((2**(CFO_DW - 1) - 1)) * $itor(180));
                    $display("PSS_detector: detected CFO frequency is %f Hz", $itor(CFO_angle) * SAMPLE_RATE / 64 / (2**(CFO_DW - 1) - 1));
                    $display("PSS detector: detected CFO DDS_inc is %d", CFO_DDS_inc);
                    CFO_state <= WAIT_FOR_PEAK;
                    CFO_angle_o <= cfo_mode == CFO_MODE_AUTO ? CFO_angle : '0;
                    CFO_DDS_inc_o <= cfo_mode == CFO_MODE_AUTO ? CFO_DDS_inc : '0;
                    CFO_valid_o <= 1 && (cfo_mode == CFO_MODE_AUTO);
                end
            end
        endcase
    end
end

//-------------------------------------------------------------------------------
// FSM for detection of peaks
// mode can be controlled by mode_i when the USE_MODE parameter is 1
//
// In SEARCH mode a valid peak is detected if one and only one PSS correlator signals peak_detected.
// In FIND mode, a peak is detected same as in SEARCH mode, except that search is limited to a certain N_id_2
// in PAUSE mode, the PSS correlators are disabled
//
// If USE_MODE is 0, the FSM is permanently in SEARCH mode
wire [1 : 0] mode_select;
assign mode_select = USE_MODE ? mode_i : SEARCH;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        N_id_2_o <= '0;
        peak_valid <= '0;
        correlator_en <= '0;
    end else begin
        case(mode_select)
            SEARCH : begin
                correlator_en <= 1;
                if ((peak_detected == 1) || (peak_detected == 2) || (peak_detected == 4)) begin
                    case (peak_detected)
                        1 : N_id_2_o <= 0;
                        2 : N_id_2_o <= 1;
                        4 : N_id_2_o <= 2;
                    endcase
                    peak_valid <= 1;
                end else begin
                    peak_valid <= 0;
                end
            end
            FIND : begin
                correlator_en <= 1;
                if (peak_detected[requested_N_id_2_i] && 
                    ((peak_detected == 1) || (peak_detected == 2) || (peak_detected == 4))) begin
                    N_id_2_o <= requested_N_id_2_i;
                    peak_valid <= 1;
                end else begin
                    peak_valid <= 0;
                end
            end
            PAUSE : begin
                correlator_en <= 0;
                peak_valid <= 0;
            end
        endcase
    end
end

assign N_id_2_valid_o = peak_valid;

PSS_detector_regmap #(
    .ID(0),
    .ADDRESS_WIDTH(AXI_ADDRESS_WIDTH),
    .CORR_DW(OUT_DW),
    .VARIABLE_NOISE_LIMIT(VARIABLE_NOISE_LIMIT),
    .VARIABLE_DETECTION_FACTOR(VARIABLE_DETECTION_FACTOR),
    .INITIAL_DETECTION_SHIFT(INITIAL_DETECTION_SHIFT)
)
PSS_detector_regmap_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),

    .mode_i(mode_i),
    .CFO_angle_i(CFO_angle_o),
    .cfo_mode_o(cfo_mode),
    .peak_counter_0_i(peak_counter_0),
    .peak_counter_1_i(peak_counter_1),
    .peak_counter_2_i(peak_counter_2),
    .noise_limit_o(noise_limit),
    .detection_shift_o(detection_shift),

    .s_axi_if_awaddr(s_axi_awaddr),
    .s_axi_if_awvalid(s_axi_awvalid),
    .s_axi_if_awready(s_axi_awready),
    .s_axi_if_wdata(s_axi_wdata),
    .s_axi_if_wstrb(s_axi_wstrb),
    .s_axi_if_wvalid(s_axi_wvalid),
    .s_axi_if_wready(s_axi_wready),
    .s_axi_if_bresp(s_axi_bresp),
    .s_axi_if_bvalid(s_axi_bvalid),
    .s_axi_if_bready(s_axi_bready),
    .s_axi_if_araddr(s_axi_araddr),
    .s_axi_if_arvalid(s_axi_arvalid),
    .s_axi_if_arready(s_axi_arready),
    .s_axi_if_rdata(s_axi_rdata),
    .s_axi_if_rresp(s_axi_rresp),
    .s_axi_if_rvalid(s_axi_rvalid),
    .s_axi_if_rready(s_axi_rready)
);

endmodule
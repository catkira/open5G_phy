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
    parameter INITIAL_CFO_MODE = 0,
    parameter CIC_RATE = 2,

    localparam SAMPLE_RATE = 1920000,
    localparam AXI_ADDRESS_WIDTH = 11
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input                                       clear_ni,
    input   wire           [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,

    input                  [1 : 0]              mode_i,
    input                  [1 : 0]              requested_N_id_2_i,
    
    output                 [IN_DW-1:0]          m_axis_out_tdata,
    output                                      m_axis_out_tvalid,
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
wire peak_valid;
wire [IN_DW - 1 : 0] cic_tdata;
wire cic_tvalid;
// set input data to CIC to 0s if correlators are disabled to prevent unwanted peaks
// wire [IN_DW - 1 : 0] cic_in_tdata = correlator_en ? s_axis_in_tdata : '0;
wire [IN_DW - 1 : 0] cic_in_tdata = s_axis_in_tdata;
wire reset_int_n = reset_ni && clear_ni;

if (CIC_RATE > 1) begin
    cic_d #(
        .INP_DW(IN_DW/2),
        .OUT_DW(IN_DW/2),
        .CIC_R(CIC_RATE),
        .CIC_N(3),
        .VAR_RATE(0)
    )
    cic_real(
        .clk(clk_i),
        .reset_n(reset_int_n),
        .s_axis_in_tdata(cic_in_tdata[IN_DW / 2 - 1 -: IN_DW / 2]),
        .s_axis_in_tvalid(s_axis_in_tvalid),
        .m_axis_out_tdata(cic_tdata[IN_DW / 2 - 1 -: IN_DW / 2]),
        .m_axis_out_tvalid(cic_tvalid)
    );

    cic_d #(
        .INP_DW(IN_DW / 2),
        .OUT_DW(IN_DW / 2),
        .CIC_R(CIC_RATE),
        .CIC_N(3),
        .VAR_RATE(0)
    )
    cic_imag(
        .clk(clk_i),
        .reset_n(reset_int_n),
        .s_axis_in_tdata(cic_in_tdata[IN_DW - 1 -: IN_DW / 2]),
        .s_axis_in_tvalid(s_axis_in_tvalid),
        .m_axis_out_tdata(cic_tdata[IN_DW - 1 -: IN_DW / 2])
    );
end else begin
    assign cic_tdata = s_axis_in_tdata;
    assign cic_tvalid = s_axis_in_tvalid;
end

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
        .reset_ni(reset_int_n),
        .s_axis_in_tdata(cic_tdata),
        .s_axis_in_tvalid(cic_tvalid),
        .enable_i(1'b1),
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
        .reset_ni(reset_int_n),
        .s_axis_in_tdata(cic_tdata),
        .s_axis_in_tvalid(cic_tvalid),
        .enable_i(1'b1),
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
        .reset_ni(reset_int_n),
        .s_axis_in_tdata(cic_tdata),
        .s_axis_in_tvalid(cic_tvalid),
        .enable_i(1'b1),
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
        .reset_ni(reset_int_n),
        .s_axis_in_tdata(cic_tdata),
        .s_axis_in_tvalid(cic_tvalid),
        .enable_i(1'b1),
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
        .reset_ni(reset_int_n),
        .s_axis_in_tdata(cic_tdata),
        .s_axis_in_tvalid(cic_tvalid),
        .enable_i(1'b1),
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
        .reset_ni(reset_int_n),
        .s_axis_in_tdata(cic_tdata),
        .s_axis_in_tvalid(cic_tvalid),
        .enable_i(1'b1),
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
    .reset_ni(reset_int_n),
    .s_axis_in_tdata(correlator_0_tdata),
    .s_axis_in_tvalid(correlator_0_tvalid),
    .noise_limit_i(noise_limit),
    .detection_shift_i(detection_shift),
    .enable_i(correlator_en),
    .peak_detected_o(peak_detected[0]),
    .score_o(score[0]),
    .peak_valid_o(peak_valid)
);

Peak_detector #(
    .IN_DW(OUT_DW),
    .WINDOW_LEN(WINDOW_LEN)
)
peak_detector_1_i(
    .clk_i(clk_i),
    .reset_ni(reset_int_n),
    .s_axis_in_tdata(correlator_1_tdata),
    .s_axis_in_tvalid(correlator_1_tvalid),
    .noise_limit_i(noise_limit),
    .detection_shift_i(detection_shift),
    .enable_i(correlator_en),
    .peak_detected_o(peak_detected[1]),
    .score_o(score[1])
);

Peak_detector #(
    .IN_DW(OUT_DW),
    .WINDOW_LEN(WINDOW_LEN)
)
peak_detector_2_i(
    .clk_i(clk_i),
    .reset_ni(reset_int_n),
    .s_axis_in_tdata(correlator_2_tdata),
    .s_axis_in_tvalid(correlator_2_tvalid),
    .noise_limit_i(noise_limit),
    .detection_shift_i(detection_shift),
    .enable_i(correlator_en),
    .peak_detected_o(peak_detected[2]),
    .score_o(score[2])    
);

reg [C_DW - 1 : 0] C0_f [0 : 2];
reg [C_DW - 1 : 0] C1_f [0 : 2];
always @(posedge clk_i) begin
    if (!reset_int_n) begin
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
    .reset_ni(reset_int_n),
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
reg N_id_2_valid;

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
    if (!reset_int_n) begin
        CFO_state <= WAIT_FOR_PEAK;
        CFO_angle_o <= '0;
        CFO_DDS_inc_o <= '0;
        CFO_valid_o <= '0;
    end else begin
        case (CFO_state)
            WAIT_FOR_PEAK : begin
                CFO_valid_o <= '0;
                if (N_id_2_valid) begin
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
reg [1 : 0] N_id_2;

always @(posedge clk_i) begin
    if (!reset_int_n) begin
        N_id_2 <= '0;
        N_id_2_valid <= '0;
        correlator_en <= '0;
    end else begin
        case(mode_select)
            SEARCH : begin
                correlator_en <= 1;
                if ((peak_detected == 1) || (peak_detected == 2) || (peak_detected == 4)) begin
                    case (peak_detected)
                        1 : N_id_2 <= 0;
                        2 : N_id_2 <= 1;
                        4 : N_id_2 <= 2;
                    endcase
                    $display("PSS detector: detected N_id_2 is %d", peak_detected == 1 ? 0 : (peak_detected == 2 ? 1 : 2));                    
                    N_id_2_valid <= 1;
                end else begin
                    N_id_2_valid <= 0;
                end
            end
            FIND : begin
                correlator_en <= 1;
                if (peak_detected[requested_N_id_2_i] && 
                    ((peak_detected == 1) || (peak_detected == 2) || (peak_detected == 4))) begin
                    N_id_2 <= requested_N_id_2_i;
                    $display("PSS detector: detected N_id_2 is %d (find mode)", requested_N_id_2_i);                    
                    N_id_2_valid <= 1;
                end else begin
                    N_id_2_valid <= 0;
                end
            end
            PAUSE : begin
                correlator_en <= 0;
                N_id_2_valid <= 0;
            end
        endcase
    end
end

// discard first 129 or peaks
// TODO: why not 128 ??
localparam PEAK_DELAY_LIMIT = CIC_RATE <= 2 ? 129 : 130; 

reg [10 : 0] peak_delay;
always @(posedge clk_i) begin
    if (!reset_int_n) peak_delay <= '0;
    else if (peak_valid) peak_delay <= peak_delay < PEAK_DELAY_LIMIT ? peak_delay + 1 : peak_delay;
end

reg peak_valid_f;
always @(posedge clk_i) peak_valid_f <= (!reset_int_n) ? '0 : peak_valid && (peak_delay == PEAK_DELAY_LIMIT);

reg [2 : 0] state;
wire peak_fifo_valid_out;
wire data_fifo_ready = ((peak_fifo_valid_out || (wait_cycle_cnt > 0)) && (state == 2)) || (state == 0);
localparam WAIT_CNT_LEN = $clog2(MULT_REUSE >> 1) > 0 ? $clog2(MULT_REUSE >> 1) : 1;
reg [WAIT_CNT_LEN - 1 : 0] wait_cnt;
reg [3 : 0] wait_cycle_cnt;
// TODO: simplift this FSM and support CIC_RATE > 2 (NFFT = 9)
always @(posedge clk_i) begin
    if (!reset_int_n) begin
        state <= '0;
        wait_cnt <= '0;
        wait_cycle_cnt <= CIC_RATE > 2 ? CIC_RATE - 2 : 0;
    end else begin
        case (state)
            0 : begin
                if (data_fifo_valid_out && data_fifo_ready) begin
                    if (MULT_REUSE <= 2) state <= CIC_RATE > 1 ? 2 : 0;
                    else begin
                        wait_cnt <= (MULT_REUSE >> 1) - 2;
                        state <= 1;
                    end
                end
            end
            1 : begin
                if (wait_cnt == 0) begin
                    if (CIC_RATE == 1)       state <= 0;
                    else if (CIC_RATE >= 2)  state <= 2;
                end
                else wait_cnt <= wait_cnt - 1;
            end
            2 : begin
                if (data_fifo_valid_out && data_fifo_ready) begin
                    if (MULT_REUSE <= 2) begin
                        if (wait_cycle_cnt == 0) begin
                            wait_cycle_cnt <= CIC_RATE > 2 ? CIC_RATE - 2 : 0;
                            state <= 0;
                        end else begin
                            wait_cnt <= (MULT_REUSE >> 1) - 2;
                            wait_cycle_cnt <= wait_cycle_cnt - 1;
                            state <= 2;
                        end
                    end else begin
                        wait_cnt <= (MULT_REUSE >> 1) - 2;
                        state <= 3;
                    end
                end
            end
            3 : begin
                if (wait_cnt == 0) begin
                    if (wait_cycle_cnt == 0) begin
                        wait_cycle_cnt <= CIC_RATE > 2 ? CIC_RATE - 2 : 0;
                        state <= 0;
                    end else begin
                        wait_cycle_cnt <= wait_cycle_cnt - 1;
                        state <= 2;
                    end
                end else wait_cnt <= wait_cnt - 1;
            end
        endcase
    end
end
wire peak_fifo_ready = ((state == 2) && data_fifo_valid_out && data_fifo_ready && (CIC_RATE > 1) && (wait_cycle_cnt == (CIC_RATE > 2 ? 2 : 0))) || ((CIC_RATE == 1) && data_fifo_valid_out);

wire [2 : 0] peak_fifo_out;
wire [31 : 0] peak_fifo_level;
AXIS_FIFO #(
    .DATA_WIDTH(3),
    .FIFO_LEN(16),
    .ASYNC(0),
    .USER_WIDTH(0)
)
peak_fifo_i(
    .clk_i(clk_i),
    .s_reset_ni(reset_int_n),

    .s_axis_in_tdata({N_id_2, N_id_2_valid}),
    .s_axis_in_tuser(),
    .s_axis_in_tvalid(peak_valid_f),

    .out_clk_i(clk_i),
    .m_reset_ni(reset_int_n),
    .m_axis_out_tdata(peak_fifo_out),
    .m_axis_out_tuser(),
    .m_axis_out_tvalid(peak_fifo_valid_out),
    .m_axis_out_tready(peak_fifo_ready),
    .m_axis_out_tlevel(peak_fifo_level)
);
assign N_id_2_o = peak_fifo_out[2:1];
assign N_id_2_valid_o = peak_fifo_valid_out && peak_fifo_ready && peak_fifo_out[0];

wire data_fifo_valid_out;
wire [31 : 0] data_fifo_level;
AXIS_FIFO #(
    .DATA_WIDTH(IN_DW),
    .FIFO_LEN(512 * (CIC_RATE > 1 ? CIC_RATE / 2 : 1)),
    .ASYNC(0),
    .USER_WIDTH(0)
)
data_fifo_i(
    .clk_i(clk_i),
    .s_reset_ni(reset_int_n),

    .s_axis_in_tdata(s_axis_in_tdata),
    .s_axis_in_tuser(),
    .s_axis_in_tvalid(s_axis_in_tvalid),

    .out_clk_i(clk_i),
    .m_reset_ni(reset_int_n),
    .m_axis_out_tdata(m_axis_out_tdata),
    .m_axis_out_tuser(),
    .m_axis_out_tvalid(data_fifo_valid_out),
    .m_axis_out_tready(data_fifo_ready),
    .m_axis_out_tlevel(data_fifo_level)
);
assign m_axis_out_tvalid = data_fifo_valid_out && data_fifo_ready;

PSS_detector_regmap #(
    .ID(0),
    .ADDRESS_WIDTH(AXI_ADDRESS_WIDTH),
    .CORR_DW(OUT_DW),
    .VARIABLE_NOISE_LIMIT(VARIABLE_NOISE_LIMIT),
    .VARIABLE_DETECTION_FACTOR(VARIABLE_DETECTION_FACTOR),
    .INITIAL_DETECTION_SHIFT(INITIAL_DETECTION_SHIFT),
    .INITIAL_CFO_MODE(INITIAL_CFO_MODE)
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
    .peak_fifo_level_i(peak_fifo_level),
    .data_fifo_level_i(data_fifo_level),
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
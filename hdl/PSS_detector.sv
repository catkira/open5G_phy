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
    parameter ALGO = 1,
    parameter WINDOW_LEN = 8,
    parameter USE_MODE = 0
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire           [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,

    input                  [1 : 0]              mode_i,
    input                  [1 : 0]              requested_N_id_2_i,
    
    output  reg            [1 : 0]              N_id_2_o,
    output  reg                                 N_id_2_valid_o,
    
    // debug outputs
    output  wire           [IN_DW-1:0]          m_axis_cic_debug_tdata,
    output  wire                                m_axis_cic_debug_tvalid,
    output  wire           [OUT_DW - 1 : 0]     m_axis_correlator_debug_tdata,
    output  wire                                m_axis_correlator_debug_tvalid,
    output                 [TAP_DW - 1 : 0]     taps_2_o [0 : PSS_LEN - 1]
);


wire [OUT_DW - 1 : 0] correlator_0_tdata, correlator_1_tdata, correlator_2_tdata;
wire correlator_0_tvalid, correlator_1_tvalid, correlator_2_tvalid;
assign m_axis_correlator_debug_tdata = correlator_2_tdata;
assign m_axis_correlator_debug_tvalid = correlator_2_tvalid;
reg [2 : 0] peak_detected; 
reg correlator_en;
reg [IN_DW-1:0] score [0 : 2];

PSS_correlator #(
    .IN_DW(IN_DW),
    .OUT_DW(OUT_DW),
    .TAP_DW(TAP_DW),
    .PSS_LEN(PSS_LEN),
    .PSS_LOCAL(PSS_LOCAL_0),
    .USE_TAP_FILE(USE_TAP_FILE),
    .TAP_FILE(TAP_FILE_0),
    .ALGO(ALGO)
)
correlator_0_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .s_axis_in_tdata(s_axis_in_tdata),
    .s_axis_in_tvalid(s_axis_in_tvalid && correlator_en),
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
    .ALGO(ALGO)
)
correlator_1_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .s_axis_in_tdata(s_axis_in_tdata),
    .s_axis_in_tvalid(s_axis_in_tvalid && correlator_en),
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
    .ALGO(ALGO)
)
correlator_2_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .s_axis_in_tdata(s_axis_in_tdata),
    .s_axis_in_tvalid(s_axis_in_tvalid && correlator_en),
    .m_axis_out_tdata(correlator_2_tdata),
    .m_axis_out_tvalid(correlator_2_tvalid),
    .taps_o(taps_2_o)
);

Peak_detector #(
    .IN_DW(OUT_DW),
    .WINDOW_LEN(WINDOW_LEN)
)
peak_detector_0_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .s_axis_in_tdata(correlator_0_tdata),
    .s_axis_in_tvalid(correlator_0_tvalid),
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
    .peak_detected_o(peak_detected[2]),
    .score_o(score[2])    
);

localparam [1 : 0]  SEARCH = 0;
localparam [1 : 0]  FIND   = 1;
localparam [1 : 0]  PAUSE  = 2;
localparam SSB_INTERVAL = $rtoi(1920000 * 0.02);
localparam TRACK_TOLERANCE = 100;
localparam CORRELATOR_DELAY = 160;
reg [$clog2(SSB_INTERVAL + TRACK_TOLERANCE) - 1 : 0] sample_cnt;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        N_id_2_o <= '0;
        N_id_2_valid_o <= '0;
        correlator_en <= '0;
    end else if (USE_MODE) begin
        case(mode_i)
            SEARCH : begin
                correlator_en <= 1;
                if ((peak_detected == 1) || (peak_detected == 2) || (peak_detected == 4)) begin
                    if      ((score[0] >= score[1]) && (score[0] >= score[2]))  N_id_2_o <=  0;
                    else if ((score[1] >= score[0]) && (score[1] >= score[2]))  N_id_2_o <=  1;
                    else if ((score[2] >= score[0]) && (score[2] >= score[1]))  N_id_2_o <=  2;            
                    N_id_2_valid_o <= 1;
                end else begin
                    N_id_2_valid_o <= 0;
                end
            end
            FIND : begin
                correlator_en <= 1;
                if (peak_detected[requested_N_id_2_i] && 
                    ((peak_detected == 1) || (peak_detected == 2) || (peak_detected == 4))) begin
                    N_id_2_o <= requested_N_id_2_i;
                    N_id_2_valid_o <= 1;
                end else begin
                    N_id_2_valid_o <= 0;
                end
            end
            PAUSE : begin
                correlator_en <= 0;
                N_id_2_valid_o <= 0;
            end
        endcase
    end else begin
        correlator_en <= 1;
        if ((peak_detected == 1) || (peak_detected == 2) || (peak_detected == 4)) begin
            if      ((score[0] >= score[1]) && (score[0] >= score[2]))  N_id_2_o <=  0;
            else if ((score[1] >= score[0]) && (score[1] >= score[2]))  N_id_2_o <=  1;
            else if ((score[2] >= score[0]) && (score[2] >= score[1]))  N_id_2_o <=  2;            
            N_id_2_valid_o <= 1;
        end else begin
            N_id_2_valid_o <= 0;
        end        
    end
end

endmodule
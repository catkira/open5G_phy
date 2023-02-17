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
    parameter ALGO = 1,
    parameter WINDOW_LEN = 8,
    parameter USE_TRACK_MODE = 0
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire           [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,
    
    output  reg            [1 : 0]              N_id_2_o,
    output  reg                                 N_id_2_valid_o,
    
    // debug outputs
    output  wire           [IN_DW-1:0]          m_axis_cic_debug_tdata,
    output  wire                                m_axis_cic_debug_tvalid,
    output  wire           [OUT_DW - 1 : 0]     m_axis_correlator_debug_tdata,
    output  wire                                m_axis_correlator_debug_tvalid
);


wire [OUT_DW - 1 : 0] correlator_0_tdata, correlator_1_tdata, correlator_2_tdata;
wire correlator_0_tvalid, correlator_1_tvalid, correlator_2_tvalid;
assign m_axis_correlator_debug_tdata = correlator_2_tdata;
assign m_axis_correlator_debug_tvalid = correlator_2_tvalid;
reg [2 : 0] peak_detected; 
reg correlator_en;

PSS_correlator #(
    .IN_DW(IN_DW),
    .OUT_DW(OUT_DW),
    .TAP_DW(TAP_DW),
    .PSS_LEN(PSS_LEN),
    .PSS_LOCAL(PSS_LOCAL_0),
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
    .ALGO(ALGO)
)
correlator_2_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .s_axis_in_tdata(s_axis_in_tdata),
    .s_axis_in_tvalid(s_axis_in_tvalid && correlator_en),
    .m_axis_out_tdata(correlator_2_tdata),
    .m_axis_out_tvalid(correlator_2_tvalid)
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
    .peak_detected_o(peak_detected[0])
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
    .peak_detected_o(peak_detected[1])
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
    .peak_detected_o(peak_detected[2])
);

reg [2 : 0]  state;
localparam [2 : 0]  SEARCH = 0;
localparam [2 : 0]  TRACK  = 1;
localparam SSB_INTERVAL = $rtoi(1920000 * 0.02);
localparam TRACK_TOLERANCE = 100;
localparam CORRELATOR_DELAY = 160;
reg [$clog2(SSB_INTERVAL + TRACK_TOLERANCE) - 1 : 0] sample_cnt;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        N_id_2_o <= '0;
        N_id_2_valid_o <= '0;
        state <= SEARCH;
        sample_cnt <= '0;
        correlator_en <= '0;
    end else begin
        case(state)
            SEARCH : begin
                correlator_en <= 1;
                 if (s_axis_in_tvalid)  sample_cnt <= sample_cnt + 1;

                 if (USE_TRACK_MODE) begin
                    if (peak_detected != 0)  state <= TRACK;
                 end
            end
            TRACK : begin
                if (sample_cnt >= (SSB_INTERVAL - TRACK_TOLERANCE - CORRELATOR_DELAY))   correlator_en <= 1;
                else  correlator_en <= 0;
                    
                if ((sample_cnt >= (SSB_INTERVAL - TRACK_TOLERANCE)) && (sample_cnt <= (SSB_INTERVAL + TRACK_TOLERANCE))) begin
                    if (peak_detected != 0) begin 
                        sample_cnt <= '0;
                        $display("PSS in track mode detected at offset %d", sample_cnt - SSB_INTERVAL);
                    end
                    if (s_axis_in_tvalid) sample_cnt <= sample_cnt + 1;
                end else if (sample_cnt > (SSB_INTERVAL + TRACK_TOLERANCE)) begin
                    $display("expected PSS was not detected, going back to SEARCH mode");
                    state <= SEARCH;
                end else begin
                    if (s_axis_in_tvalid) sample_cnt <= sample_cnt + 1;
                    N_id_2_valid_o <= 0;
                end
            end
        endcase
    end    
end

always @(posedge clk_i) begin
    if (!reset_ni) begin
        N_id_2_o <= '0;
        N_id_2_valid_o <= '0;
    end else begin
        if (peak_detected[0])       N_id_2_o <=  0;
        else if (peak_detected[1])  N_id_2_o <=  1;
        else if (peak_detected[2])  N_id_2_o <=  2;

        N_id_2_valid_o <= peak_detected != 0;
    end
end

`ifdef COCOTB_SIM
initial begin
  $dumpfile ("debug.vcd");
  $dumpvars (0, PSS_detector);
end
`endif

endmodule
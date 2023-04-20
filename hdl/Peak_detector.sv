`timescale 1ns / 1ns

module Peak_detector
#(
    parameter IN_DW = 32,              // input data width
    parameter WINDOW_LEN = 8,          // length of average window, should be power of 2
    parameter VARIABLE_NOISE_LIMIT = 0,

    localparam FIXED_NOISE_LIMIT = 2**(IN_DW/2),
    localparam DETECTION_FACTOR = 16
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input                  [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,
    input                  [15 : 0]             noise_limit_i,
    output  reg                                 peak_detected_o,
    output  reg            [IN_DW-1:0]          score_o
);

reg [IN_DW - 1 : 0] in_buffer [0 : WINDOW_LEN - 1];
reg [IN_DW - 1 + $clog2(WINDOW_LEN) : 0] average;
reg [$clog2(WINDOW_LEN) : 0] init_counter = '0;
localparam AVERAGE_SHIFT = $clog2(WINDOW_LEN) - $clog2(DETECTION_FACTOR);

wire [15 : 0] noise_limit;
if (VARIABLE_NOISE_LIMIT)  assign noise_limit = noise_limit_i;
else                       assign noise_limit = FIXED_NOISE_LIMIT;

genvar ii;
for (ii = 0; ii < WINDOW_LEN; ii++) begin
    always @(posedge clk_i) begin
        if (!reset_ni) in_buffer[ii] <= '0;
        else if (s_axis_in_tvalid) begin
            if (ii == 0)  in_buffer[ii] <= s_axis_in_tdata;
            else          in_buffer[ii] <= in_buffer[ii - 1];
        end
    end
end

reg                 in_valid_f;
reg [IN_DW - 1 : 0] in_data_f;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        peak_detected_o <= '0;
        init_counter <= '0;
        score_o <= '0;
        average <= '0;
        in_valid_f <= '0;
        in_data_f <= '0;
    end else begin
        in_valid_f <= s_axis_in_tvalid;

        if (s_axis_in_tvalid) begin
            if (init_counter < WINDOW_LEN)  init_counter <= init_counter + 1;

            average <= average + in_buffer[0] - in_buffer[WINDOW_LEN - 1];

            if (init_counter == WINDOW_LEN) begin
                if ((AVERAGE_SHIFT > 0 ? s_axis_in_tdata > (average >> AVERAGE_SHIFT)
                    : s_axis_in_tdata > (average << -AVERAGE_SHIFT)) && (s_axis_in_tdata > noise_limit)) begin
                    peak_detected_o <= 1;
                    score_o <= AVERAGE_SHIFT > 0 ? s_axis_in_tdata - (average >> AVERAGE_SHIFT)
                        : s_axis_in_tdata - (average << -AVERAGE_SHIFT);
                end else begin
                    peak_detected_o <= '0;
                    score_o <= '0;
                end
            end else begin
                peak_detected_o <= '0;
                score_o <= '0;
            end
        end else begin
            peak_detected_o <= '0;
        end
    end
end
endmodule
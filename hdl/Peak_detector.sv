`timescale 1ns / 1ns

module Peak_detector
#(
    parameter IN_DW = 32,              // input data width
    parameter WINDOW_LEN = 8          // length of average window, should be power of 2
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input                  [IN_DW - 1 : 0]      s_axis_in_tdata,
    input                                       s_axis_in_tvalid,
    input                  [IN_DW - 1 : 0]      noise_limit_i,
    input                  [7 : 0]              detection_shift_i,
    input                                       enable_i,
    output  reg                                 peak_detected_o,
    output  reg                                 peak_valid_o,
    output  reg            [IN_DW - 1 : 0]      score_o
);

reg [IN_DW - 1 : 0] in_buffer [0 : WINDOW_LEN - 1];
reg [IN_DW - 1 + $clog2(WINDOW_LEN) : 0] average;
reg [$clog2(WINDOW_LEN) : 0] init_counter = '0;
wire signed [7 : 0] total_shift = $clog2(WINDOW_LEN) - detection_shift_i;

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

always @(posedge clk_i) begin
    if (!reset_ni)   peak_valid_o <= '0;
    else            peak_valid_o <= s_axis_in_tvalid && (init_counter == WINDOW_LEN);
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
                if ((total_shift > 0 ? (s_axis_in_tdata > (average >> total_shift)) && (s_axis_in_tdata > noise_limit_i)
                    : (s_axis_in_tdata > (average << -total_shift))) && (s_axis_in_tdata > noise_limit_i)) begin
                    peak_detected_o <= 1 && enable_i;
                    score_o <= total_shift > 0 ? s_axis_in_tdata - (average >> total_shift)
                        : s_axis_in_tdata - (average << -total_shift);
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
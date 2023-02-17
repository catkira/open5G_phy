`timescale 1ns / 1ns

module Peak_detector
#(
    parameter IN_DW = 32,              // input data width
    parameter WINDOW_LEN = 8           // length of average window, should be power of 2
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire           [IN_DW-1:0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,
    output  reg                                 peak_detected_o,
    output  reg            [IN_DW-1:0]          score_o
);

reg [IN_DW - 1 : 0] in_buffer [0 : WINDOW_LEN - 1];
reg [IN_DW - 1 + $clog2(WINDOW_LEN) : 0] average;
reg [$clog2(WINDOW_LEN) : 0] init_counter = '0;
localparam DETECTION_FACTOR = 16;
localparam AVERAGE_SHIFT = $clog2(WINDOW_LEN) - $clog2(DETECTION_FACTOR);

always @(posedge clk_i) begin
    if (!reset_ni) begin
        foreach (in_buffer[i])
            in_buffer[i] = '0;
        peak_detected_o <= '0;
        init_counter <= '0;
        score_o <= '0;
    end else begin
        if (s_axis_in_tvalid) begin
            if (init_counter < WINDOW_LEN)
                init_counter <= init_counter + 1;
            for (integer i = 0; i < WINDOW_LEN; i++) begin
                if (i == 0) begin
                    in_buffer[i] <= s_axis_in_tdata;
                end else begin
                    in_buffer[i] <= in_buffer[i-1];
                end
            end
            average = 0;
            for (integer i = 0; i < WINDOW_LEN - 1; i++) begin
                average = average + in_buffer[i];
            end
            if (init_counter == WINDOW_LEN) begin
                peak_detected_o <= AVERAGE_SHIFT > 0 ? s_axis_in_tdata > (average >> AVERAGE_SHIFT)
                    : s_axis_in_tdata > (average << -AVERAGE_SHIFT);
                score_o <= s_axis_in_tdata - (average >> AVERAGE_SHIFT);
            end else begin
                peak_detected_o <= '0;
                score_o <= '0;
            end
        end
    end
end
endmodule
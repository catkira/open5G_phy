`timescale 1ns / 1ns

module SSS_detector
#(
    localparam N_id_1_MAX = 335,
    localparam N_id_MAX = 1007
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire                                s_axis_in_tdata,
    input                                       s_axis_in_tvalid,
    input   wire   [1 : 0]                      N_id_2_i,
    input   wire                                N_id_2_valid_i,
    output  reg    [$clog2(N_id_1_MAX) - 1 : 0] m_axis_out_tdata,
    output  reg                                 m_axis_out_tvalid,
    output  reg    [$clog2(N_id_MAX) - 1 : 0]   N_id_o,
    output  reg                                 N_id_valid_o
);

localparam SSS_LEN = 127;

//localparam [$clog2(10) - 1 : 0]times_5 [0 : 2] = '{10, 5, 0};
// stupid iverilog does not support multidimensional localparams,
// there have to use a reg that is assigned a constant value at reset
reg [$clog2(10) - 1 : 0] times_5 [0 : 2];
reg [$clog2(35) - 1 : 0] times_15 [0 : 2];

reg [SSS_LEN - 1 : 0] sss_in;
reg [1 : 0]           N_id_2;

localparam NUM_STATES = 5;
reg [$clog2(NUM_STATES) - 1 : 0] state= '0;
reg [$clog2(SSS_LEN - 1) - 1 : 0] copy_counter, copy_counter_m_seq;
reg [$clog2(SSS_LEN - 1) - 1 : 0] compare_counter;
reg [$clog2(SSS_LEN - 1) - 1 : 0] acc_max;
reg signed [$clog2(SSS_LEN - 1) : 0] acc;
wire signed [$clog2(SSS_LEN - 1) : 0] abs_acc = acc[$clog2(SSS_LEN - 1)] ? ~acc + 1 : acc;
localparam SHIFT_MAX = 112;
reg [$clog2(SHIFT_MAX) - 1 : 0] shift_cur, shift_max;

reg [$clog2(N_id_1_MAX) - 1 : 0] N_id_1, N_id_1_det;

wire lfsr_out_0, lfsr_out_1, lfsr_valid;
localparam LFSR_N = 7;
LFSR #(
    .N(LFSR_N),
    .TAPS('h11),
    .START_VALUE(1),
    .VARIABLE_CONFIG(0)
)
lfsr_0
(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .data_o(lfsr_out_0),
    .valid_o(lfsr_valid)
);
LFSR #(
    .N(LFSR_N),
    .TAPS('h03),
    .START_VALUE(1),
    .VARIABLE_CONFIG(0)
)
lfsr_1
(
    .clk_i(clk_i),
    .reset_ni(reset_ni),
    .data_o(lfsr_out_1)
);
reg [SSS_LEN - 1 : 0] m_seq_0, m_seq_1;
wire [$clog2(SSS_LEN - 1) - 1 : 0] m_seq_0_pos, m_seq_1_pos;
//  if SSS_LEN would be 128, roll operation would be very easy by just using overflows
//  however since SSS_LEN is 127 it is a bit more complicated
reg [$clog2(SSS_LEN - 1) - 1 : 0] m_0, m_1, m_0_start;
reg [3 : 0] div_112; // is (N_id_1 / 112)
reg m_seq_0_wrap, m_seq_1_wrap;
assign m_seq_0_pos = m_0 + compare_counter + m_seq_0_wrap;
assign m_seq_1_pos = m_1 + compare_counter + m_seq_1_wrap;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        times_5[0] = 0;
        times_5[1] = 5;
        times_5[2] = 10;
        times_15[0] = 0;
        times_15[1] = 15;
        times_15[2] = 30;
        m_axis_out_tdata <= '0;
        m_axis_out_tvalid <= '0;
        N_id_valid_o <= '0;
        N_id_o <= '0;
        copy_counter <= '0;
        copy_counter_m_seq <= '0;
        state <= '0;
        compare_counter <= '0;
        shift_cur <= '0;
        m_0 <= '0;
        m_1 <= '0;
        div_112 <= '0;
        N_id_1 <= '0;
        N_id_1_det <= '0;
        m_0_start <= '0;
        acc_max <= '0;
        acc <= '0;
        m_seq_0_wrap <= '0;
        m_seq_1_wrap <= '0;
        m_seq_0 <= '0;
        m_seq_1 <= '0;
        // $display("reset");
    end else begin
        if (state == 0) begin   
            // copy SSS into internal buffer and create m_seq_0 and m_seq_1
            // m_0 = 15 * int((N_id_1 / 112)) + 5 * N_id_2
            // m_1 = N_id_1 % 112
            // d_SSS = (1 - 2 * np.roll(mseq_0, -m_0)) * (1 - 2 * np.roll(mseq_1, -m_1))

            if (lfsr_valid && (copy_counter_m_seq < SSS_LEN)) begin
                // $display("store %d %d", lfsr_out_0, lfsr_out_1);
                m_seq_0[copy_counter_m_seq] <= lfsr_out_0;
                m_seq_1[copy_counter_m_seq] <= lfsr_out_1;
                copy_counter_m_seq <= copy_counter_m_seq + 1;
            end

            if (N_id_2_valid_i) begin
                // $display("N_id_2 = %d", N_id_2_i);
                // m_0_start = 5 * N_id_2_i;
                N_id_2 <= N_id_2_i;
                m_0_start <= times_5[N_id_2_i];  // optimized to not use multiplication
                m_0 <= times_5[N_id_2_i];
                m_1 <= 0;
            end
            if (s_axis_in_tvalid) begin
                sss_in[copy_counter] <= s_axis_in_tdata;
                // $display("ss_in[%d] = %d", copy_counter, s_axis_in_tdata);
                if (copy_counter == SSS_LEN - 1) begin
                    state <= 1;
                    // $display("enter state 1");
                end
                copy_counter <= copy_counter + 1;
            end
        end else if (state == 1) begin // compare input to single SSS sequence
            if (compare_counter == 0) begin
                // acc = '0;  // this is not needed
                shift_max = '0;
                // $display("N_id_1 = %d  shift_cur = %d", N_id_1, shift_cur);
                // $display("m_0 = %d  m_1 = %d  mod = %d", m_seq_0_pos, m_seq_1_pos, div_112);
            end

            if (m_seq_0_pos == SSS_LEN - 1) begin
                m_seq_0_wrap <= 1;
            end
            if (m_seq_1_pos == SSS_LEN - 1) begin
                m_seq_1_wrap <= 1;
            end

            if (compare_counter == SSS_LEN - 1) begin
                // $display("correlation = %d", acc);
                if (abs_acc > acc_max) begin
                    acc_max <= abs_acc;
                    m_axis_out_tdata <= N_id_1;
                    N_id_o <= N_id_1 + N_id_1 + N_id_1 + N_id_2;
                    // $display("best N_id_1 so far is %d", N_id_1);
                end
                compare_counter <= '0;
                m_seq_0_wrap <= '0;
                m_seq_1_wrap <= '0;            
                acc <= '0;

                if (N_id_1 == N_id_1_MAX) begin
                    m_axis_out_tvalid <= 1;
                    N_id_valid_o <= 1;
                    shift_cur <= '0;
                    div_112 <= '0;
                    acc_max <= '0;
                    state <= 0; // back to init state
                end else begin
                    if (shift_cur == SHIFT_MAX - 1) begin
                        // m_0 <= m_0_start + 15 * (div_112 + 1);
                        m_0 <= m_0_start + times_15[div_112 + 1]; // optimized to not use multiplication
                        m_1 <= 0;
                        div_112 <= div_112 + 1;
                        shift_cur <= '0;
                    end else begin
                        m_1 <= m_1 + 1;
                        shift_cur <= shift_cur + 1;
                    end
                    N_id_1 <= N_id_1 + 1;
                    // $display("test next: N_id_1 = %d  N_id_2 = %d", N_id_1 + 1, m_0_start / 5);
                end
            end else begin
                // $display("pos0 = %d  pos1 = %d  seq0 = %d  seq1 = %d  wrap0 = %d  wrap1 = %d  acc = %d", m_seq_0_pos, m_seq_1_pos, m_seq_0[m_seq_0_pos], m_seq_1[m_seq_1_pos], m_seq_0_wrap, m_seq_1_wrap, acc);
                // $display("cnt = %d   %d <-> %d", compare_counter, sss_in[compare_counter],  m_seq_0[m_seq_0_pos] ^ m_seq_1[m_seq_1_pos]);

                if      (sss_in[compare_counter] == ~(m_seq_0[m_seq_0_pos] ^ m_seq_1[m_seq_1_pos]))     acc <= acc + 1;
                else if (sss_in[compare_counter] ==  (m_seq_0[m_seq_0_pos] ^ m_seq_1[m_seq_1_pos]))     acc <= acc - 1;
                compare_counter <= compare_counter + 1;
            end
        end else begin
            $display("ERROR: undefined state %d", state);
        end
    end
end

endmodule
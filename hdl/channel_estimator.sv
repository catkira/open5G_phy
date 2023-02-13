`timescale 1ns / 1ns

module channel_estimator #(
    parameter IN_DW = 32,           // input data width
    localparam OUT_DW = IN_DW,
    localparam NFFT = 8,
    localparam FFT_LEN = 2 ** NFFT,
    localparam MAX_CELL_ID = 1007
)
(
    input                                           clk_i,
    input                                           reset_ni,
    input   wire       [IN_DW - 1 : 0]              s_axis_in_tdata,
    input                                           s_axis_in_tvalid,
    input   wire       [$clog2(MAX_CELL_ID) - 1: 0] N_id_i,
    input                                           N_id_valid_i,
    input                                           PBCH_start_i,

    output  reg        [OUT_DW - 1 : 0]             m_axis_out_tdata,
    output  reg                                     m_axis_out_tvalid,

    // debug ports
    output  reg        [1 : 0]                      debug_PBCH_DMRS_o,
    output  reg                                     debug_PBCH_DMRS_valid_o
);

reg [$clog2(MAX_CELL_ID) - 1: 0] N_id, N_id_used;
reg [3 : 0] state_PBCH_DMRS;
localparam PBCH_DMRS_LEN = 144;
reg [2 : 0] PBCH_DMRS [0 : PBCH_DMRS_LEN - 1];
reg [$clog2(2 * PBCH_DMRS_LEN) - 1 : 0] PBCH_DMRS_cnt;
reg [2 : 0] ibar_SSB;

localparam LFSR_N = 31;
reg lfsr_out_0, lfsr_out_1;
reg lfsr_valid;
reg [LFSR_N - 1 : 0] c_init;
reg LFSR_reset_n;
reg LFSR_load_config;

LFSR #(
    .N(LFSR_N),
    .TAPS('h11),
    .START_VALUE(1),
    .VARIABLE_CONFIG(0)
)
lfsr_0
(
    .clk_i(clk_i),
    .reset_ni(LFSR_reset_n),
    .data_o(lfsr_out_0),
    .valid_o(lfsr_valid)
);
LFSR #(
    .N(LFSR_N),
    .TAPS('h17),
    .START_VALUE(1),
    .VARIABLE_CONFIG(1)
)
lfsr_1
(
    .clk_i(clk_i),
    .reset_ni(LFSR_reset_n),
    .load_config_i(LFSR_load_config),
    .taps_i('h17),
    .start_value_i(c_init),
    .data_o(lfsr_out_1)
);

always @(posedge clk_i) begin
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
        m_axis_out_tvalid <= '0;
        N_id <= '0;
    end else begin
        if (N_id_valid_i)  begin
            N_id <= N_id_i;
        end
    end
end


// this process updates the PBCH_DMRS after a new N_id was set
always @(posedge clk_i) begin
    if (!reset_ni) begin
        state_PBCH_DMRS <= '0;
        for (integer i = 0; i < PBCH_DMRS_LEN; i = i + 1) begin
            PBCH_DMRS[i] <= '0;
        end
        PBCH_DMRS_cnt <= '0;
        LFSR_reset_n <= '0;
        LFSR_load_config <= '0;
        debug_PBCH_DMRS_o <= '0;
        debug_PBCH_DMRS_valid_o <= '0;
        ibar_SSB <= 3'b010;
    end else begin
        case (state_PBCH_DMRS)
            0: begin
                if (N_id_valid_i) begin
                    N_id_used <= N_id_i;
                    ibar_SSB <= 3'b010;
                    c_init <= (((ibar_SSB + 1) * ((N_id_i >> 2) + 1)) << 11) +  ((ibar_SSB + 1) + (N_id_i[1 : 0] % 4) << 6);
                    $display("cinit = %x", c_init);
                    state_PBCH_DMRS <= 2;
                    PBCH_DMRS_cnt <= '0;
                    LFSR_reset_n <= '1;
                    LFSR_load_config <= 1;
                end
            end
            2: begin
                LFSR_load_config <= '0;
                if (PBCH_DMRS_cnt == (2*PBCH_DMRS_LEN - 1)) begin
                    state_PBCH_DMRS <= 3;
                end
                PBCH_DMRS_cnt <= PBCH_DMRS_cnt + 1;
                if (PBCH_DMRS_cnt[0] == 0) PBCH_DMRS[PBCH_DMRS_cnt >> 1][0] <= lfsr_out_0 ^ lfsr_out_1;
                else                       PBCH_DMRS[PBCH_DMRS_cnt >> 1][1] <= lfsr_out_0 ^ lfsr_out_1;

                if (PBCH_DMRS_cnt[0] == 0) debug_PBCH_DMRS_o[0] <= lfsr_out_0 ^ lfsr_out_1;
                else                       debug_PBCH_DMRS_o[1] <= lfsr_out_0 ^ lfsr_out_1;
                debug_PBCH_DMRS_valid_o <= PBCH_DMRS_cnt[0];
            end
            3: begin
                debug_PBCH_DMRS_valid_o <= '0;
                state_PBCH_DMRS <= '0;
                LFSR_reset_n <= '0;
            end
        endcase
    end
end

`ifdef COCOTB_SIM
initial begin
  $dumpfile ("debug.vcd");
  $dumpvars (0, channel_estimator);
end
`endif

endmodule
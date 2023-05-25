module SSB_extractor #(
    parameter IN_DW = 16,           // input data width
    parameter NFFT = 8,
    parameter BLK_EXP_LEN = 8,

    localparam SFN_MAX = 1023,
    localparam SUBFRAMES_PER_FRAME = 20,
    localparam SYM_PER_SF = 14,
    localparam SFN_WIDTH = $clog2(SFN_MAX),
    localparam SUBFRAME_NUMBER_WIDTH = $clog2(SUBFRAMES_PER_FRAME - 1),
    localparam SYMBOL_NUMBER_WIDTH = $clog2(SYM_PER_SF - 1),
    localparam USER_WIDTH = SFN_WIDTH + SUBFRAME_NUMBER_WIDTH + SYMBOL_NUMBER_WIDTH + BLK_EXP_LEN + 1
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire       [IN_DW - 1 : 0]          s_axis_in_tdata,
    input   wire       [USER_WIDTH - 1 : 0]     s_axis_in_tuser,    
    input                                       s_axis_in_tlast,
    input                                       s_axis_in_tvalid,

    output  reg        [IN_DW - 1 : 0]          m_axis_out_tdata,
    output  reg        [USER_WIDTH - 1 : 0]     m_axis_out_tuser,
    output  reg                                 m_axis_out_tlast,
    output  reg                                 m_axis_out_tvalid
);

wire [SYMBOL_NUMBER_WIDTH - 1 : 0] sym = s_axis_in_tuser[SYMBOL_NUMBER_WIDTH + BLK_EXP_LEN - 1 -: SYMBOL_NUMBER_WIDTH];
localparam FFT_LEN = 2 * NFFT;
reg [$clog2(FFT_LEN) - 1 : 0] sc_cnt;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        m_axis_out_tvalid <= '0;
        m_axis_out_tdata <= '0;
        m_axis_out_tuser <= '0;
        m_axis_out_tlast <= '0;
        sc_cnt <= '0;
    end else begin
        if ((sym >= 0) && (sym <= 3) && (sc_cnt >= 8) && (sc_cnt <= 248))  begin
            m_axis_out_tdata <= s_axis_in_tdata;
            m_axis_out_tvalid <= s_axis_in_tvalid;
            m_axis_out_tuser <= s_axis_in_tuser;
            m_axis_out_tlast <= s_axis_in_tlast;
        end else begin
            m_axis_out_tvalid <= '0;
            m_axis_out_tdata <= '0;
            m_axis_out_tuser <= '0;
            m_axis_out_tlast <= '0;
        end

        if (s_axis_in_tvalid) begin
            if (sc_cnt == FFT_LEN - 1)  sc_cnt <= '0;
            else                        sc_cnt <= sc_cnt + 1;
        end
    end
end

endmodule
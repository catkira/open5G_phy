module FFT_demod #(
    parameter IN_DW = 32,           // input data width
    parameter HALF_CP_ADVANCE = 1,
    parameter OUT_DW = 16,
    parameter NFFT = 8,
    parameter BWP_LEN = 240,
    parameter BLK_EXP_LEN = 8,
    localparam FFT_LEN = 2 ** NFFT,
    localparam CP1 = 20 * FFT_LEN / 256,
    localparam CP2 = 18 * FFT_LEN / 256,
    localparam MAX_CP_LEN = CP1,
    localparam SFN_MAX = 1023,
    localparam SUBFRAMES_PER_FRAME = 20,
    localparam SYM_PER_SF = 14,
    localparam SFN_WIDTH = $clog2(SFN_MAX),
    localparam SUBFRAME_NUMBER_WIDTH = $clog2(SUBFRAMES_PER_FRAME - 1),
    localparam SYMBOL_NUMBER_WIDTH = $clog2(SYM_PER_SF - 1),
    localparam USER_WIDTH_IN = SFN_WIDTH + SUBFRAME_NUMBER_WIDTH + SYMBOL_NUMBER_WIDTH + $clog2(MAX_CP_LEN),
    localparam USER_WIDTH_OUT = SFN_WIDTH + SUBFRAME_NUMBER_WIDTH + SYMBOL_NUMBER_WIDTH + BLK_EXP_LEN + 1
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire       [IN_DW - 1 : 0]          s_axis_in_tdata,
    input   wire       [USER_WIDTH_IN - 1 : 0]  s_axis_in_tuser,    
    input                                       s_axis_in_tlast,
    input                                       s_axis_in_tvalid,
    input                                       SSB_start_i,
    output  reg        [OUT_DW - 1 : 0]         m_axis_out_tdata,
    output  reg        [USER_WIDTH_OUT -1  : 0] m_axis_out_tuser,
    output  reg                                 m_axis_out_tlast,
    output  reg                                 m_axis_out_tvalid,
    output                                      PBCH_valid_o,
    output                                      SSS_valid_o
);

// frame information (sfn, subframe number, symbol_number) go into this FIFO because FFT_core does not have tuser
reg meta_FIFO_valid_in;
wire meta_FIFO_valid_out;
reg meta_FIFO_out_ready;
wire [SFN_WIDTH + SUBFRAME_NUMBER_WIDTH + SYMBOL_NUMBER_WIDTH - 1 : 0] meta_FIFO_out_data;
AXIS_FIFO #(
    .DATA_WIDTH(SFN_WIDTH + SUBFRAME_NUMBER_WIDTH + SYMBOL_NUMBER_WIDTH),
    .FIFO_LEN(16),
    .USER_WIDTH(0),
    .ASYNC(0)
)
meta_FIFO_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),

    .s_axis_in_tdata(s_axis_in_tuser[USER_WIDTH_IN - 1 : $clog2(MAX_CP_LEN)]),
    .s_axis_in_tvalid(meta_FIFO_valid_in),

    .m_axis_out_tdata(meta_FIFO_out_data),
    .m_axis_out_tready(meta_FIFO_out_ready),
    .m_axis_out_tvalid(meta_FIFO_valid_out)
);


// this FSM is at the input to the FFT core
reg [IN_DW - 1 : 0] in_data_f;
reg in_valid_f;
reg [OUT_DW - 1 : 0] out_data_f;
localparam SSB_LEN = 4;
reg [$clog2(MAX_CP_LEN) - 1 : 0] current_CP_len;
reg [$clog2(MAX_CP_LEN) - 1: 0] CP_cnt;
reg [$clog2(FFT_LEN) : 0] in_cnt;
localparam SYMS_BTWN_SSB = 14 * 20;
reg [2 : 0] state_in;
localparam [2 : 0]  STATE_IN_SKIP_CP = 0;
localparam [2 : 0]  STATE_IN_PROCESS_SYMBOL = 1;
localparam [2 : 0]  STATE_IN_SKIP_END = 2;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        state_in <= STATE_IN_SKIP_CP;
        in_cnt <= '0;
        current_CP_len <= CP2;
        CP_cnt <= HALF_CP_ADVANCE ? CP2 / 2 : 0;
        meta_FIFO_valid_in <= '0;
        in_data_f <= '0;
        in_valid_f <= '0;
    end else begin
        if (state_in == STATE_IN_SKIP_CP) begin // skip CP
            if (s_axis_in_tvalid) begin
                in_cnt <= '0;
                if (CP_cnt == (current_CP_len - 1)) begin
                    state_in <= STATE_IN_PROCESS_SYMBOL;
                    CP_cnt <= '0;
                end else begin
                    CP_cnt <= CP_cnt + 1;
                end
            end
        end else if (state_in == STATE_IN_PROCESS_SYMBOL) begin // process symbol
            if (s_axis_in_tvalid && (in_cnt == FFT_LEN - 2))  meta_FIFO_valid_in <= 1;
            else                                              meta_FIFO_valid_in <= '0;

            if (s_axis_in_tvalid) begin
                if (in_cnt != (FFT_LEN - 1)) begin
                    in_cnt <= in_cnt + 1;
                end else if (s_axis_in_tlast) begin
                    state_in <= STATE_IN_SKIP_CP;
                    CP_cnt <= HALF_CP_ADVANCE ? current_CP_len >> 1 : 0;
                end else begin
                    state_in <= STATE_IN_SKIP_END;
                    CP_cnt <= HALF_CP_ADVANCE ? current_CP_len >> 1 : 0;
                end
            end
        end else if (state_in == STATE_IN_SKIP_END) begin // skip repetition at end of symbol
            if (s_axis_in_tvalid && s_axis_in_tlast) state_in <= STATE_IN_SKIP_CP;
        end

        if (s_axis_in_tvalid) begin
            current_CP_len <= s_axis_in_tuser[$clog2(MAX_CP_LEN) - 1 : 0];
            in_data_f <= s_axis_in_tdata;
            in_valid_f <= s_axis_in_tvalid;
        end
    end
end


// This process generates sync signals at the FFT output
// BPW start and end for PDCCH and PDSCH symbols
localparam SC_START = FFT_LEN / 2 - BWP_LEN / 2;
localparam SC_END = SC_START + BWP_LEN;

// BPW start and len for SSS and PBCH symbols
localparam PBCH_LEN = 240;
localparam PBCH_START = FFT_LEN / 2 - PBCH_LEN / 2;

localparam SSS_LEN = 127;
localparam SSS_START = FFT_LEN / 2 - (SSS_LEN + 1) / 2;

reg [$clog2(SYMS_BTWN_SSB) - 1 : 0] current_out_symbol;
reg PBCH_valid;
reg SSS_valid;
reg PBCH_symbol;
reg last_SC;
reg [$clog2(FFT_LEN) - 1 : 0] out_cnt;
reg [USER_WIDTH_OUT - 1 : 0] meta_out;
wire valid_SC = (out_cnt >= SC_START) && (out_cnt <= SC_END - 1);
wire valid_PBCH_SC = (out_cnt >= PBCH_START) && (out_cnt <= PBCH_START + PBCH_LEN - 1);
wire valid_SSS_SC = (out_cnt >= SSS_START) && (out_cnt <= SSS_START + SSS_LEN - 1);
always @(posedge clk_i) begin
    if (!reset_ni) begin
        out_cnt <= '0;
        SSS_valid <= '0;
        PBCH_valid <= '0;
        PBCH_symbol <= '0;
        current_out_symbol <= '0;
        last_SC <= '0;
    end else begin
        if (fft_val) begin
            last_SC <= (out_cnt == (FFT_LEN - 1 - SC_START));

            PBCH_symbol <= (current_out_symbol == 0);
            meta_FIFO_out_ready <= out_cnt == 0;
            if (meta_FIFO_valid_out)  meta_out <= {meta_FIFO_out_data, blk_exp, current_out_symbol == 0};
            
            if (out_cnt == (FFT_LEN - 1)) begin
                if (current_out_symbol == SYMS_BTWN_SSB - 1) begin
                    current_out_symbol <= '0;
                end else begin
                    // $display("state = 1");
                    current_out_symbol <= current_out_symbol + 1;
                end
                out_cnt <= '0;
            end else begin
                out_cnt <= out_cnt + 1;
            end

            PBCH_valid <= valid_SC && (current_out_symbol == 0);
            SSS_valid  <= valid_SSS_SC && (current_out_symbol == 1);
        end else begin
            PBCH_valid <= '0;
            SSS_valid <= '0;
            last_SC <= '0;
        end
    end
end

wire [OUT_DW - 1 : 0] fft_result;
wire [IN_DW / 2 - 1 : 0] fft_result_re_long, fft_result_im_long;
wire [OUT_DW / 2 - 1 : 0] fft_result_re, fft_result_im;
wire [BLK_EXP_LEN - 1 : 0] blk_exp;
assign fft_result_re = fft_result_re_long[IN_DW / 2 - 1 -: OUT_DW / 2];
assign fft_result_im = fft_result_im_long[IN_DW / 2 - 1 -: OUT_DW / 2];

wire fft_sync = fft_val && (out_cnt == 0);
wire fft_val;
reg fft_val_f;

wire fft_in_en = in_valid_f && (state_in == STATE_IN_PROCESS_SYMBOL);

fft #(
    .NFFT(NFFT),
    .FORMAT(0),
    .DATA_WIDTH(IN_DW / 2),
    .TWDL_WIDTH(IN_DW / 2),
    .XSERIES("NEW"),   // use "OLD" for Zynq7, "NEW" for MPSoC
    .USE_MLT(0),
    .SHIFTED(1),
    .DBS(1)
)
fft(
    .clk(clk_i),
    .rst(!reset_ni),
    .di_im(in_data_f[IN_DW - 1 : IN_DW / 2]),
    .di_re(in_data_f[IN_DW / 2 - 1 : 0]),
    .di_en(fft_in_en),

    .do_re(fft_result_re_long),
    .do_im(fft_result_im_long),
    .blk_exp_o(blk_exp),
    .do_vl(fft_val)
);

// This process corrects 'phase CFO' caused by CP
if (HALF_CP_ADVANCE) begin
    localparam MULT_DELAY = 6;
    reg [MULT_DELAY - 1 : 0] PBCH_valid_delay;
    reg [MULT_DELAY - 1 : 0] SSS_valid_delay;
    reg [MULT_DELAY - 1 : 0] last_SC_delay;
    reg [MULT_DELAY - 1 : 0] PBCH_symbol_delay;
    reg [USER_WIDTH_OUT - 1 : 0] meta_delay [MULT_DELAY - 1 : 0];

    reg [OUT_DW - 1 : 0] coeff [0 : 2**NFFT - 1];
    reg [NFFT - 1 : 0] coeff_idx;

    reg PBCH_valid_f;
    reg SSS_valid_f;
    reg last_SC_f;
    reg PBCH_symbol_f;
    reg [USER_WIDTH_OUT - 1 : 0] meta_delay_f;
    assign PBCH_valid_o = PBCH_valid_f;
    assign SSS_valid_o = SSS_valid_f;
    assign m_axis_out_tuser = meta_delay_f;
    assign m_axis_out_tlast = last_SC_f;

    initial begin
        real PI = 3.1415926535;
        integer CP_LEN = CP2;
        integer CP_ADVANCE = CP2 / 2;
        real angle_step = 2 * PI * $itor((CP_LEN - CP_ADVANCE)) / $itor((2**NFFT));
        real angle_acc = 0;
        // if real variables are declared inside the for loop, bugs appear, fking shit
        for (integer i = 0; i < 2**NFFT; i = i + 1) begin
            coeff[i][OUT_DW / 2 - 1 : 0]      = $cos(angle_acc + PI * (CP_LEN - CP_ADVANCE)) * (2 ** (OUT_DW / 2 - 1) - 1);
            coeff[i][OUT_DW - 1 : OUT_DW / 2] = $sin(angle_acc + PI * (CP_LEN - CP_ADVANCE)) * (2 ** (OUT_DW / 2 - 1) - 1);
            angle_acc = angle_acc + angle_step;
        end
    end

    complex_multiplier #(
        .OPERAND_WIDTH_A(OUT_DW / 2),
        .OPERAND_WIDTH_B(OUT_DW / 2),
        .OPERAND_WIDTH_OUT(OUT_DW / 2),
        .STAGES(6),
        .BLOCKING(0),
        .GROWTH_BITS(-2)
    )
    complex_multiplier_i(
        .aclk(clk_i),
        .aresetn(reset_ni),
        .s_axis_a_tdata(out_data_f),
        .s_axis_a_tvalid(fft_val_f),
        .s_axis_b_tdata(coeff[coeff_idx]),
        .s_axis_b_tvalid(fft_val_f),

        .m_axis_dout_tdata(m_axis_out_tdata),
        .m_axis_dout_tvalid(m_axis_out_tvalid)
    );

    always @(posedge clk_i) begin
        if (!reset_ni) begin
            coeff_idx <= '0;
            fft_val_f <= '0;
            out_data_f <= '0;
            PBCH_valid_delay <= '0;
            SSS_valid_delay <= '0;
            last_SC_delay <= '0;
            for (integer i = 0; i < MULT_DELAY; i = i + 1) meta_delay[i] <= '0;
            SSS_valid_f <= '0;
            PBCH_valid_f <= '0;
            last_SC_f <= '0;
            PBCH_symbol_f <= '0;
        end else begin
            fft_val_f <= fft_val && valid_SC;
            out_data_f <= {fft_result_im, fft_result_re};
            SSS_valid_delay[0] <= SSS_valid;
            PBCH_valid_delay[0] <= PBCH_valid;
            last_SC_delay[0] <= last_SC;
            PBCH_symbol_delay[0] <= PBCH_symbol;
            meta_delay[0] <= meta_out;
            for (integer i = 0; i < (MULT_DELAY - 1); i = i + 1) begin
                SSS_valid_delay[i+1] <= SSS_valid_delay[i];
                PBCH_valid_delay[i+1] <= PBCH_valid_delay[i];
                last_SC_delay[i+1] <= last_SC_delay[i];
                PBCH_symbol_delay[i+1] <= PBCH_symbol_delay[i];
                meta_delay[i+1] <= meta_delay[i];
            end
            SSS_valid_f <= SSS_valid_delay[MULT_DELAY - 1];
            PBCH_valid_f <= PBCH_valid_delay[MULT_DELAY - 1];
            last_SC_f <= last_SC_delay[MULT_DELAY - 1];
            PBCH_symbol_f <= PBCH_symbol_delay[MULT_DELAY - 1];
            meta_delay_f <= meta_delay[MULT_DELAY - 1];

            if (fft_sync) coeff_idx <= '0;
            else coeff_idx <= coeff_idx + 1;
        end
    end
end else begin
    assign SSS_valid_o = SSS_valid;
    assign PBCH_valid_o = PBCH_valid;

    always @(posedge clk_i) begin
        if (!reset_ni) begin
            m_axis_out_tdata <= '0;
            m_axis_out_tuser <= '0;
            m_axis_out_tlast <= '0;
            m_axis_out_tvalid <= '0;
        end else begin
            m_axis_out_tdata <= {fft_result_im, fft_result_re};
            m_axis_out_tlast <= last_SC;
            m_axis_out_tuser <= meta_out;
            m_axis_out_tvalid <= fft_val && valid_SC;
        end
    end
end

endmodule
module FFT_demod #(
    parameter IN_DW = 32,           // input data width
    parameter CP_ADVANCE = 9,
    localparam OUT_DW = IN_DW,
    localparam NFFT = 8,
    localparam FFT_LEN = 2 ** NFFT,
    localparam CP_LEN = 18
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input   wire       [IN_DW - 1 : 0]          s_axis_in_tdata,
    input                                       s_axis_in_tvalid,
    input                                       SSB_start_i,
    output  reg        [OUT_DW - 1 : 0]         m_axis_out_tdata,
    output  reg                                 m_axis_out_tvalid,
    output  reg                                 PBCH_start_o,
    output  reg                                 SSS_start_o,
    output  reg                                 PBCH_valid_o,
    output  reg                                 SSS_valid_o,
    output  reg                                 symbol_start_o
);

reg [IN_DW - 1 : 0] in_data_f;
reg in_valid_f;
reg [OUT_DW - 1 : 0] out_data_f;
reg [$clog2(FFT_LEN) - 1 : 0] out_cnt;
localparam SSB_LEN = 4;
reg [2 : 0] state, state2;
reg [$clog2(CP_LEN) : 0] CP_cnt;
reg [$clog2(FFT_LEN) : 0] in_cnt;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        state2 <= '0;
        in_cnt <= '0;
        CP_cnt <= '0;
    end else if (state2 == 0) begin // wait for SSB
        if (SSB_start_i) begin
            CP_cnt <= CP_LEN - CP_ADVANCE;
            state2 <= 1;
            // $display("- state2 <= 2");
        end
        out_cnt <= '0;
    end else if (state2 == 1) begin // skip CP
        if (CP_cnt == (CP_LEN - 1)) begin
            state2 <= 2;
            // $display("state2 <= 2");
            CP_cnt <= '0;
        end else begin
            // $display("skipping CP %d", fft_in_en);
            CP_cnt <= s_axis_in_tvalid ? CP_cnt + 1 : CP_cnt;
        end
    end else if (state2 == 2) begin //
        if (in_cnt != (FFT_LEN - 1)) begin
            in_cnt <= s_axis_in_tvalid ? in_cnt + 1 : in_cnt;
        end else begin
            in_cnt <= '0;
            // $display("state2 <= 1");
            state2 <= 1;
        end
    end
    in_data_f <= s_axis_in_tdata;
    in_valid_f <= s_axis_in_tvalid;
end

reg [10 : 0] current_out_symbol;
reg PBCH_start;
reg PBCH_valid;
reg SSS_start;
reg SSS_valid;
reg symbol_start;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        out_cnt <= '0;
        PBCH_start <= '0;
        SSS_start <= '0;
        SSS_valid <= '0;
        PBCH_valid <= '0;
        state <= '0;
        current_out_symbol <= '0;
    end else begin
        if (state == 0) begin  // wait for start of SSB
            current_out_symbol <= '0;
            if (SSB_start_i) begin
                state <= 1;
            end
        end else if (state == 1) begin  // wait for start of fft output
            if (fft_val) begin
                state <= 2;
                // $display("state = 2");
                // $display("current_out_symbol = %d", current_out_symbol);
            end
            SSS_valid_o <= '0;
            PBCH_valid_o <= '0;
        end else if (state == 2) begin // output one symbol
            out_cnt <= out_cnt + 1;
            if (out_cnt == (FFT_LEN - 1)) begin
                // $display("state = 1");
                state <= 1;
                current_out_symbol <= current_out_symbol + 1;
            end
        end
        PBCH_start <= (state == 2) && (out_cnt == 0) &&  (current_out_symbol == 0);
        PBCH_valid <=(state == 2) && (current_out_symbol == 0);
        SSS_start <= ((state == 2) || (state == 1)) && (out_cnt == 0) && (current_out_symbol == 1);
        SSS_valid <= (state == 2) && (current_out_symbol == 1);
        symbol_start <= (state == 2) && (out_cnt == 0);            
    end
end

wire [OUT_DW - 1 : 0] fft_result;
wire [OUT_DW / 2 - 1 : 0] fft_result_re, fft_result_im;
wire fft_sync = (state == 2) && (out_cnt == 0);
wire fft_val;
reg fft_val_f;

wire fft_in_en = in_valid_f && (state2 == 2);

fft #(
    .NFFT(NFFT),
    .FORMAT(0),
    .DATA_WIDTH(IN_DW / 2),
    .TWDL_WIDTH(IN_DW / 2),
    .XSERIES("NEW"),
    .USE_MLT(0),
    .SHIFTED(1)
)
fft(
    .clk(clk_i),
    .rst(!reset_ni),
    .di_im(in_data_f[IN_DW - 1 : IN_DW / 2]),
    .di_re(in_data_f[IN_DW / 2 - 1 : 0]),
    .di_en(fft_in_en),

    .do_re(fft_result_re),
    .do_im(fft_result_im),
    .do_vl(fft_val)
);


if (CP_ADVANCE != CP_LEN) begin
    localparam MULT_DELAY = 6;
    reg [MULT_DELAY - 1: 0] PBCH_start_delay;
    reg [MULT_DELAY - 1 : 0] PBCH_valid_delay;
    reg [MULT_DELAY - 1 : 0] SSS_start_delay;
    reg [MULT_DELAY - 1 : 0] SSS_valid_delay;

    reg [OUT_DW - 1 : 0] coeff [0 : 2**NFFT - 1];
    reg [NFFT - 1 : 0] coeff_idx;

    reg [OUT_DW - 1 : 0] out_data_ff;
    reg fft_val_ff;

    initial begin
        real PI = 3.1415926535;
        real angle_step = 2 * PI * $itor((CP_LEN - CP_ADVANCE)) / $itor((2**NFFT));
        real angle_acc = 0;
        // if real variables are declared inside the for loop, bugs appear, fking shit
        for (integer i = 0; i < 2**NFFT; i = i + 1) begin
            coeff[i][OUT_DW / 2 - 1 : 0]      = $cos(angle_acc + PI * (CP_LEN - CP_ADVANCE)) * (2 ** (OUT_DW / 2 - 1) - 1);
            coeff[i][OUT_DW - 1 : OUT_DW / 2] = $sin(angle_acc + PI * (CP_LEN - CP_ADVANCE)) * (2 ** (OUT_DW / 2 - 1) - 1);
            // $display("coeff[%d] = %x,  angle = %f", i, coeff[i], angle_acc);

            angle_acc = angle_acc + angle_step;
            // if (angle_acc > PI) angle_acc = angle_acc - 2*PI; 
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
        .s_axis_a_tdata(out_data_ff),
        .s_axis_a_tvalid(fft_val_ff),
        .s_axis_b_tdata(coeff[coeff_idx]),
        .s_axis_b_tvalid(fft_val_ff),

        .m_axis_dout_tdata(m_axis_out_tdata),
        .m_axis_dout_tvalid(m_axis_out_tvalid)
    );

    always @(posedge clk_i) begin
        if (!reset_ni) begin
            coeff_idx <= '0;
            fft_val_f <= '0;
            fft_val_ff <= '0;
            out_data_f <= '0;
            out_data_ff <= '0;
            PBCH_start_delay <= '0;
            PBCH_valid_delay <= '0;
            SSS_start_delay <= '0;
            SSS_valid_delay <= '0;
            PBCH_start_o <= '0;
            SSS_start_o <= '0;
            SSS_valid_o <= '0;
            PBCH_valid_o <= '0;
        end else begin
            fft_val_f <= fft_val;
            fft_val_ff <= fft_val_f;
            out_data_f <= {fft_result_im, fft_result_re};
            out_data_ff <= out_data_f;
            SSS_start_delay[0] <= SSS_start;
            SSS_valid_delay[0] <= SSS_valid;
            PBCH_start_delay[0] <= PBCH_start;
            PBCH_valid_delay[0] <= PBCH_valid;
            for (integer i = 0; i < (MULT_DELAY - 1); i = i + 1) begin
                SSS_start_delay[i+1] <= SSS_start_delay[i];
                SSS_valid_delay[i+1] <= SSS_valid_delay[i];
                PBCH_start_delay[i+1] <= PBCH_start_delay[i];
                PBCH_valid_delay[i+1] <= PBCH_valid_delay[i];
            end
            SSS_start_o <= SSS_start_delay[MULT_DELAY - 1];
            SSS_valid_o <= SSS_valid_delay[MULT_DELAY - 1];
            PBCH_start_o <= PBCH_start_delay[MULT_DELAY - 1];
            PBCH_valid_o <= PBCH_valid_delay[MULT_DELAY - 1];

            if (fft_sync) coeff_idx <= '0;
            else coeff_idx <= coeff_idx + 1;
        end
    end
end else begin
    // this comb block will eliminate some regs
    // use of logic type would make this cleaner
    always @(*) begin
        SSS_start_o = SSS_start;
        SSS_valid_o = SSS_valid;
        PBCH_start_o = PBCH_start;
        PBCH_valid_o = PBCH_valid;
    end

    always @(posedge clk_i) begin
        if (!reset_ni) begin
            fft_val_f <= '0;
            out_data_f <= '0;
            m_axis_out_tvalid <= '0;
            m_axis_out_tdata <= '0;
        end else begin
            fft_val_f <= fft_val;
            out_data_f <= {fft_result_im, fft_result_re};
            m_axis_out_tvalid <= fft_val_f;
            m_axis_out_tdata <= out_data_f;
        end
    end
end

endmodule
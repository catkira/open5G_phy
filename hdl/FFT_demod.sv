module FFT_demod #(
    parameter IN_DW = 32,           // input data width
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
reg fft_sync_f;
reg PBCH_start_f, SSS_start_f;
reg [2 : 0] state, state2;
reg [10 : 0] CP_cnt;
reg [$clog2(FFT_LEN) : 0] in_cnt;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        state2 <= '0;
        in_cnt <= '0;
        CP_cnt <= '0;
    end else if (state2 == 0) begin // wait for SSB
        if (SSB_start_i) begin
            // CP for first symbol is already skipped
            state2 <= 2;
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

// reg [16 : 0] val_cnt;

reg [10 : 0] current_out_symbol;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
        PBCH_start_o <= '0;
        SSS_start_o <= '0;
        out_cnt <= '0;
        out_data_f <= '0;
        PBCH_start_f <= '0;
        SSS_start_f <= '0;
        SSS_valid_o <= '0;
        PBCH_valid_o <= '0;
        state <= '0;
        current_out_symbol <= '0;
        // val_cnt <= '0;
    end else begin
        // if (fft_val) val_cnt <= val_cnt + 1;
        // if (fft_val) $display("val = %d, val_cnt = %d, state = %d  SSS_start = %d", fft_val, val_cnt, state, SSS_start_o);
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
        out_data_f <= {fft_result_im, fft_result_re};
        m_axis_out_tdata <= out_data_f;
        fft_sync_f <= fft_sync;
        PBCH_start_o <= (state == 2) && (out_cnt == 0) &&  (current_out_symbol == 0);
        PBCH_valid_o <=(state == 2) && (current_out_symbol == 0);
        SSS_start_o <= ((state == 2) || (state == 1)) && (out_cnt == 0) && (current_out_symbol == 1);
        SSS_valid_o <= (state == 2) && (current_out_symbol == 1);
        symbol_start_o <= fft_sync_f;
    end
end

wire [OUT_DW - 1 : 0] fft_result;
wire [OUT_DW / 2 - 1 : 0] fft_result_re, fft_result_im;
wire fft_sync;
wire fft_val;
reg fft_val_f;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        fft_val_f <= '0;
        m_axis_out_tvalid <= '0;
    end else begin
        fft_val_f <= fft_val;
        m_axis_out_tvalid <= fft_val_f;
    end
end

wire fft_in_en = in_valid_f && (state2 == 2);

fft #(
    .NFFT(NFFT),
    .FORMAT(0),
    .DATA_WIDTH(IN_DW / 2),
    .TWDL_WIDTH(IN_DW / 2),
    .XSERIES("NEW"),
    .USE_MLT(0)
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

endmodule
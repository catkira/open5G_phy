module FFT_demod #(
    parameter IN_DW = 32,           // input data width
    localparam OUT_DW = 42,         // fixed for now because of FFT
    localparam FFT_LEN = 256,       // fixed for now because of FFT
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
        end
        out_cnt <= '0;
    end else if (state2 == 1) begin // skip CP
        if (CP_cnt == (CP_LEN - 1)) begin
            state2 <= 2;
            CP_cnt <= '0;
        end else begin
            CP_cnt <= s_axis_in_tdata ? CP_cnt + 1 : CP_cnt;
        end
    end else if (state2 == 2) begin //
        if (in_cnt != (FFT_LEN - 1)) begin
            in_cnt <= s_axis_in_tdata ? in_cnt + 1 : in_cnt;
        end else begin
            in_cnt <= '0;
            state2 <= 1;
        end
    end
    in_data_f <= s_axis_in_tdata;
    in_valid_f <= s_axis_in_tvalid;
end

reg [10 : 0] current_out_symbol;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
        m_axis_out_tvalid <= '0;
        PBCH_start_o <= '0;
        SSS_start_o <= '0;
        out_cnt <= '0;
        out_data_f <= '0;
        fft_sync_f <= '0;
        PBCH_start_f <= '0;
        SSS_start_f <= '0;
        SSS_valid_o <= '0;
        PBCH_valid_o <= '0;
        state <= '0;
        current_out_symbol <= '0;
    end else begin
        if (fft_sync) $display("sync");

        if (state == 0) begin  // wait for start of SSB
            current_out_symbol <= '0;
            if (SSB_start_i) begin
                state <= 1;
            end
        end else if (state == 1) begin  // wait for start of fft output
            if (fft_sync) begin
                state <= 2;
                // $display("current_out_symbol = %d", current_out_symbol);
            end
            SSS_valid_o <= '0;
            PBCH_valid_o <= '0;
            m_axis_out_tvalid <= '0;
        end else if (state == 2) begin // output one symbol
            out_cnt <= out_cnt + 1;
            if (out_cnt == (FFT_LEN - 1)) begin
                state <= 1;
                current_out_symbol <= current_out_symbol + 1;
            end

            if (current_out_symbol == 0 || current_out_symbol == 2) begin
                PBCH_valid_o <= 1;
            end else begin
                PBCH_valid_o <= '0;
            end

            if (current_out_symbol == 1) begin
                SSS_valid_o <= 1;
            end else begin
                SSS_valid_o <= '0;
            end
            m_axis_out_tvalid <= 1;
        end
        out_data_f <= fft_result;
        m_axis_out_tdata <= out_data_f;
        fft_sync_f <= fft_sync;
        PBCH_start_o <= fft_sync_f && (current_out_symbol == 0); 
        SSS_start_o <= fft_sync_f && (current_out_symbol == 1);
        symbol_start_o <= fft_sync_f;
    end
end

wire [OUT_DW - 1 : 0] fft_result;
wire fft_sync;

fftmain #(
)
fft(
    .i_clk(clk_i),
    .i_reset(!reset_ni),
    .i_ce(in_valid_f && (state2 == 2)),
    .i_sample({in_data_f[IN_DW / 2 - 1 : 0], in_data_f[IN_DW - 1 : IN_DW / 2]}),
    .o_result(fft_result),
    .o_sync(fft_sync)
);


endmodule
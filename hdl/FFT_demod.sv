module FFT_demod #(
    parameter IN_DW = 32,           // input data width
    localparam OUT_DW = 42,         // fixed for now because of FFT
    localparam FFT_LEN = 256        // fixed for now because of FFT
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
    output  reg                                 symbol_start_o
);

reg SSB_start;
reg [IN_DW - 1 : 0] in_data_f;
reg in_valid_f;
reg [OUT_DW - 1 : 0] out_data_f;
reg FFT_out_active;
reg [$clog2(FFT_LEN) - 1 : 0] out_cnt;
localparam SSB_LEN = 4;
reg [$clog2(SSB_LEN) - 1 : 0] symbol_cnt;
reg fft_sync_f;
reg PBCH_start_f, SSS_start_f;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
        m_axis_out_tvalid <= '0;
        FFT_out_active <= '0;
        PBCH_start_o <= '0;
        SSS_start_o <= '0;
        out_cnt <= '0;
        out_data_f <= '0;
        symbol_cnt <= '0;
        fft_sync_f <= '0;
        PBCH_start_f <= '0;
        SSS_start_f <= '0;
    end else begin
        SSB_start <= SSB_start_i ? 1 : SSB_start;
        in_data_f <= s_axis_in_tdata;
        in_valid_f <= s_axis_in_tvalid;
        out_data_f <= fft_result;
        m_axis_out_tdata <= out_data_f;
        fft_sync_f <= fft_sync;

        if (SSB_start_i) begin
            symbol_cnt <= '0;
        end else if (fft_sync) begin
            // prevent symbol_cnt overflow
            symbol_cnt <= symbol_cnt < SSB_LEN ? symbol_cnt + 1 : symbol_cnt;
        end
        PBCH_start_f <= fft_sync && (symbol_cnt == 0); 
        SSS_start_f <= fft_sync && (symbol_cnt == 1);
        PBCH_start_o <= PBCH_start_f;
        SSS_start_o <= SSS_start_f;
        symbol_start_o <= fft_sync_f;

        // FFT_out_active stays high for FFT_LEN after it was started by fft_sync
        m_axis_out_tvalid <= fft_sync ? 1 : FFT_out_active && (out_cnt < FFT_LEN);
        FFT_out_active <= fft_sync ? 1 : FFT_out_active && (out_cnt < FFT_LEN);
        out_cnt <= (fft_sync || (out_cnt != 0)) ? out_cnt + 1 : out_cnt;
    end
end

wire [OUT_DW - 1 : 0] fft_result;
wire fft_sync;

fftmain #(
)
fft(
    .i_clk(clk_i),
    .i_reset(!reset_ni),
    .i_ce(in_valid_f && SSB_start),
    .i_sample({in_data_f[IN_DW / 2 - 1 : 0], in_data_f[IN_DW - 1 : IN_DW / 2]}),
    .o_result(fft_result),
    .o_sync(fft_sync)
);


endmodule
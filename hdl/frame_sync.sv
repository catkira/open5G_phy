`timescale 1ns / 1ns

module frame_sync #(
    parameter IN_DW = 32,
    parameter NFFT = 8,
    parameter CLK_FREQ = 3840000,

    localparam FFT_LEN = 2 ** NFFT,
    localparam CP1_LEN = 20 * FFT_LEN / 256,
    localparam CP2_LEN = 18 * FFT_LEN / 256,
    localparam OUT_DW = IN_DW,
    localparam MAX_CP_LEN = CP1_LEN,
    localparam SFN_MAX = 1023,
    localparam SUBFRAMES_PER_FRAME = 20,
    localparam SYM_PER_SF = 14,
    localparam SFN_WIDTH = $clog2(SFN_MAX),
    localparam SUBFRAME_NUMBER_WIDTH = $clog2(SUBFRAMES_PER_FRAME - 1),
    localparam SYMBOL_NUMBER_WIDTH = $clog2(SYM_PER_SF - 1),
    localparam USER_WIDTH = SFN_WIDTH + SUBFRAME_NUMBER_WIDTH + SYMBOL_NUMBER_WIDTH + $clog2(MAX_CP_LEN),
    localparam AXI_ADDRESS_WIDTH = 11
)
(
    input                                           clk_i,
    input                                           reset_ni,
    input   wire       [IN_DW - 1 : 0]              s_axis_in_tdata,
    input                                           s_axis_in_tvalid,

    input              [1 : 0]                      N_id_2_i,
    input                                           N_id_2_valid_i,
    input              [2 : 0]                      ibar_SSB_i,
    input                                           ibar_SSB_valid_i,

    output  reg        [1 : 0]                      PSS_detector_mode_o,
    output  reg        [1 : 0]                      requested_N_id_2_o,

    // interface to sample_id FIFO
    output  wire                                    sample_id_valid,

    // output to FFT_demod
    output  reg        [OUT_DW - 1 : 0]             m_axis_out_tdata,
    output  reg        [USER_WIDTH - 1 : 0]         m_axis_out_tuser,
    output  reg                                     m_axis_out_tlast,
    output  reg                                     m_axis_out_tvalid,
    output  reg                                     symbol_start_o,
    output  reg                                     SSB_start_o,
    output  reg                                     reset_fft_no,
    output  reg        [1 : 0]                      N_id_2_o,
    output  reg                                     N_id_2_valid_o,
    output                                          clear_detector_no,                                     

    // output to regmap
    output  wire       [1 : 0]                      state_o,
    output  wire signed   [7 : 0]                   sample_cnt_mismatch_o,
    output  wire       [15 : 0]                     missed_SSBs_o,
    output  wire       [31 : 0]                     clks_btwn_SSBs_o,
    output  wire       [31 : 0]                     num_disconnects_o,

    // AXI lite interface
    // write address channel
    input           [AXI_ADDRESS_WIDTH - 1 : 0] s_axi_awaddr,
    input                                       s_axi_awvalid,
    output  reg                                 s_axi_awready,
    
    // write data channel
    input           [31 : 0]                    s_axi_wdata,
    input           [ 3 : 0]                    s_axi_wstrb,
    input                                       s_axi_wvalid,
    output  reg                                 s_axi_wready,

    // write response channel
    output          [ 1 : 0]                    s_axi_bresp,
    output  reg                                 s_axi_bvalid,
    input                                       s_axi_bready,

    // read address channel
    input           [AXI_ADDRESS_WIDTH - 1 : 0] s_axi_araddr,
    input                                       s_axi_arvalid,
    output  reg                                 s_axi_arready,

    // read data channel
    output  reg     [31 : 0]                    s_axi_rdata,
    output          [ 1 : 0]                    s_axi_rresp,
    output  reg                                 s_axi_rvalid,
    input                                       s_axi_rready
);

reg [$clog2(MAX_CP_LEN) - 1: 0] CP_len;
reg [SFN_WIDTH - 1 : 0] sfn;
reg [SUBFRAME_NUMBER_WIDTH - 1 : 0] subframe_number;
reg [SYMBOL_NUMBER_WIDTH - 1 : 0] sym_cnt;
reg [$clog2(MAX_CP_LEN) - 1 : 0] current_CP_len;
reg [IN_DW - 1 : 0] s_axis_in_tdata_f;
reg out_valid;
reg out_last;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
        m_axis_out_tuser <= '0;
        s_axis_in_tdata_f <= '0;
        m_axis_out_tvalid <= '0;
        m_axis_out_tlast <= '0;
    end else begin
        m_axis_out_tvalid <= out_valid;
        m_axis_out_tlast <= out_last;
        s_axis_in_tdata_f <= s_axis_in_tdata;
        m_axis_out_tdata <= s_axis_in_tdata_f;
        m_axis_out_tuser <= {sfn, subframe_number, sym_cnt, current_CP_len};
    end
end

always @(posedge clk_i) begin
    if (!reset_ni)  requested_N_id_2_o <= '0;
    else if (N_id_2_valid_i)  requested_N_id_2_o <= N_id_2_i;
end

// process that forwards N_id_2
always @(posedge clk_i) begin
    N_id_2_o <= reset_ni ? N_id_2_i : '0;
    N_id_2_valid_o <= reset_ni ? N_id_2_valid_i : '0;
end

reg              [2 : 0]                      ibar_SSB;
always @(posedge clk_i) begin
    if (!reset_ni) ibar_SSB <= '0;
    else ibar_SSB <= ibar_SSB_valid_i ? ibar_SSB_i : ibar_SSB;
end

// ---------------------------------------------------------------------------------------------------//
// FSM for controlling PSS detector
localparam [1 : 0] PSS_DETECTOR_MODE_SEARCH = 0;
localparam [1 : 0] PSS_DETECTOR_MODE_FIND   = 1;
localparam [1 : 0] PSS_DETECTOR_MODE_PAUSE  = 1;
localparam CLKS_20MS = $rtoi(CLK_FREQ * 0.02);
localparam CLKS_PSS_EARLY_WAKEUP = $rtoi(CLK_FREQ * 0.00001); // start PSS detector 0.01 ms before expected SSB
localparam CLKS_PSS_LATE_TOLERANCE = $rtoi(CLK_FREQ * 0.00001); // keep PSS detector running until 0.01ms after expected SSB
reg [$clog2(CLKS_20MS + CLKS_PSS_LATE_TOLERANCE) - 1 : 0] clks_since_SSB, clks_since_SSB_f;
reg [1 : 0] PSS_state;
localparam [1 : 0] SEARCH_PSS = 0;
localparam [1 : 0] FIND_PSS = 1;
localparam [1 : 0] PAUSE_PSS = 2;
reg [15 : 0] missed_SSBs;
assign missed_SSBs_o = missed_SSBs;
assign clks_btwn_SSBs_o = clks_since_SSB_f;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        PSS_state <= SEARCH_PSS;
        clks_since_SSB <= '0;
        PSS_detector_mode_o <= '0;
        missed_SSBs <= '0;
        clks_since_SSB_f <= '0;
    end else begin
        PSS_detector_mode_o <= PSS_state;
        case (PSS_state)
            SEARCH_PSS : begin  // search PSS with any N_id_2
                if (N_id_2_valid_i) begin
                    missed_SSBs <= '0;
                    PSS_state <= PAUSE_PSS;
                    clks_since_SSB <= 1;
                    clks_since_SSB_f <= '0;
                end else begin
                    clks_since_SSB <= clks_since_SSB + 1;
                end
            end
            PAUSE_PSS : begin // PAUSE until next PSS is expected    
                if (clks_since_SSB > (CLKS_20MS - CLKS_PSS_EARLY_WAKEUP)) begin
                    PSS_state <= FIND_PSS;
                end else begin
                    clks_since_SSB <= clks_since_SSB + 1;
                end
            end
            FIND_PSS : begin  // FIND PSS with same N_id_2 as last one
                if (clks_since_SSB > (CLKS_20MS + CLKS_PSS_LATE_TOLERANCE)) begin
                    $display("frame_sync: did not find PSS, going back to SEARCH mode!");
                    PSS_state <= SEARCH_PSS;
                    missed_SSBs <= missed_SSBs + 1;
                end else if (N_id_2_valid_i) begin
                    $display("frame_sync: found PSS in FIND mode after %d clk's, putting PSS detectore in PAUSE mode", clks_since_SSB);
                    clks_since_SSB_f <= clks_since_SSB;
                    PSS_state <= PAUSE_PSS;
                    clks_since_SSB <= 1;
                end else begin
                    clks_since_SSB <= clks_since_SSB + 1;
                end
            end
        endcase
    end
end

// This function is only used for debugging for now
// assumes SSB pattern case A (TS 38.213)
function is_SSB_location;
    input [SFN_WIDTH - 1 : 0] sfn;
    input [SUBFRAME_NUMBER_WIDTH - 1 : 0] subframe;
    input [SYMBOL_NUMBER_WIDTH - 1 : 0] sym;
    input [$clog2(FFT_LEN + MAX_CP_LEN) - 1 : 0] sample_cnt;
    input [2 : 0] ibar_SSB;
    input [$clog2(MAX_CP_LEN) - 1 : 0] current_CP_len;
    input [3 : 0] sample_ahead;
    begin
        if ((sample_cnt + sample_ahead) % (FFT_LEN + current_CP_len) != 0) is_SSB_location = 0;
        else begin
            case (ibar_SSB)
                0 : begin
                    is_SSB_location = (sample_cnt == 0) && (sym == 2) && (subframe == 0);
                end
                1 : begin
                    is_SSB_location = (sample_cnt == 0) && (sym == 8) && (subframe == 0);
                end
                2 : begin
                    is_SSB_location = (sample_cnt == 0) && (sym == 2) && (subframe == 1);
                end
                3 : begin
                    is_SSB_location = (sample_cnt == 0) && (sym == 8) && (subframe == 1);
                end
            endcase
        end
    end
endfunction

// ---------------------------------------------------------------------------------------------------//
// FSM for keeping track of current subframe number and symbol number within a subframe 
// and sending the current CP length to the FFT_demod core
//
// sfn is the current system frame number
// subframe_number is current subframe number within the current frame
// sym_cnt is the current symbol number within the current subframe
//
// TODO:  - add timeout to WAIT_FOR_IBAR state
//        - make SYNCED and WAIT_FOR_IBAR substates of a single state and reduce duplicate code
reg [$clog2(FFT_LEN + MAX_CP_LEN) - 1 : 0] sample_cnt;
reg find_SSB;

localparam SYMS_BTWN_SSB = SUBFRAMES_PER_FRAME * SYM_PER_SF;
reg [$clog2(SYMS_BTWN_SSB + 100) - 1 : 0] syms_since_last_SSB;

reg [1 : 0] state;
assign state_o = state;
localparam [1 : 0] WAIT_FOR_SSB = 0;
localparam [1 : 0] WAIT_FOR_IBAR = 1; // not used
localparam [1 : 0] SYNCED = 2;
localparam [1 : 0] RESET_DETECTOR = 3;
localparam CIC_RATE = 2 ** (NFFT - 7);

// 2 samples at 1.92 MSPS
// because PSS detector has precision +- 1 sample at 1.92 MSPS
localparam FIND_SAMPLES_TOLERANCE = 2 * CIC_RATE;

reg signed [7 : 0] sample_cnt_mismatch;
assign sample_cnt_mismatch_o = sample_cnt_mismatch;
wire end_of_symbol_ = sample_cnt == (FFT_LEN + current_CP_len - 1);
wire end_of_symbol = (end_of_symbol_ && !find_SSB) || (find_SSB && N_id_2_valid_i);
wire end_of_subframe = end_of_symbol && (sym_cnt == SYM_PER_SF - 1);
wire end_of_frame = end_of_subframe && (subframe_number == SUBFRAMES_PER_FRAME - 1);
wire [$clog2(FFT_LEN + MAX_CP_LEN) - 1 : 0] sample_cnt_next = end_of_symbol ? '0 : sample_cnt + 1;
wire [SYMBOL_NUMBER_WIDTH - 1 : 0] sym_cnt_next = end_of_symbol ? (end_of_subframe ? 0 : sym_cnt + 1) : sym_cnt;
wire [SUBFRAME_NUMBER_WIDTH - 1 : 0] subframe_number_next = end_of_subframe ? (end_of_frame ? 0 : subframe_number + 1) : subframe_number;
wire [SFN_WIDTH - 1 : 0] sfn_next = end_of_frame ? (sfn == SFN_MAX - 1 ? 0 : sfn + 1) : sfn;
assign clear_detector_no = !(state == RESET_DETECTOR);
reg [31 : 0] num_disconnects;
assign num_disconnects_o = num_disconnects;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        sfn <= '0;
        subframe_number <= '0;
        sym_cnt <= '0;
        sample_cnt <= '0;
        state <= RESET_DETECTOR;
        current_CP_len <= CP2_LEN;
        find_SSB <= '0;
        SSB_start_o <= '0;
        syms_since_last_SSB <= '0;
        out_valid <= '0;
        out_last <= '0;
        sample_cnt_mismatch <= '0;
        reset_fft_no <= '0;
        num_disconnects <= '0;
    end else begin
        case (state)
            RESET_DETECTOR: begin
                state <= WAIT_FOR_SSB;
            end
            WAIT_FOR_SSB: begin
                SSB_start_o <= '0;
                find_SSB <= '0;                
                if (N_id_2_valid_i) begin
                    sample_cnt <= 0;
                    out_valid <= s_axis_in_tvalid;
                    // SSB_pattern for case A is [2, 8, 16, 22]
                    // whether we are on symbol 2 or symbol 8 depends on ibar_SSB
                    // assume for now that we are at symbol 2
                    // it might have to be corrected once ibar_SSB arrives
                    current_CP_len <= CP2_LEN;
                    sym_cnt <= 2;
                    state <= SYNCED;
                    syms_since_last_SSB <= '0;
                    // SSB_start_o <= 1;
                    reset_fft_no <= 1;
                end else begin
                    // SSB_start_o <= '0;
                    out_valid <= '0;
                    reset_fft_no <= '0;
                end
            end
            WAIT_FOR_IBAR: begin  // not used
            end
            SYNCED: begin
                if (ibar_SSB_valid_i) begin
                    // TODO: adjust sym_cnt, subframe, sfn accordingly
                end

                if (find_SSB) begin
                    if (N_id_2_valid_i) begin
                        // expected sample_cnt for the next SSB is the last sample of the previous symbol, if actual sample_cnt deviates +-1, perform realignment
                        $display("frame_sync: SSB at sfn = %d, subframe = %d, symbol = %d, sample = %d", sfn, subframe_number, sym_cnt, sample_cnt);
                        $display("frame_sync: is_SSB_location = %d", is_SSB_location(sfn_next, subframe_number_next, sym_cnt_next, sample_cnt_next, 0, current_CP_len, 0));
                        if (sample_cnt == (FFT_LEN + current_CP_len - 1)) begin
                            sample_cnt_mismatch <= 0;
                            // SSB arrives as expected, no STO correction needed
                            $display("frame_sync: SSB is on time");
                        end else if (sample_cnt <= FIND_SAMPLES_TOLERANCE) begin
                            sample_cnt_mismatch <= sample_cnt + 1;
                            // SSB arrives too late
                            // correct this STO by outputting symbol_start and SSB_start a bit later
                            $display("frame_sync: SSB is %d samples too late", sample_cnt);
                        end else if (sample_cnt >= (FFT_LEN + current_CP_len - 1 - FIND_SAMPLES_TOLERANCE)) begin
                            sample_cnt_mismatch <= sample_cnt - (FFT_LEN + current_CP_len - 1);
                            // SSB arrives too early
                            // correct this STO by outputting symbol_start and SSB_start a bit earlier
                            $display("frame_sync: SSB is %d samples too early", (FFT_LEN + current_CP_len) - sample_cnt);
                        end
                        find_SSB <= '0;
                    end

                    if (sample_cnt == 3) begin
                        // could not find SSB, connection is lost 
                        // go back to search mode (state 0)
                        $display("frame_sync: could not find SSB, connection is lost!");
                        state <= RESET_DETECTOR;
                        num_disconnects <= num_disconnects + 1;
                    end
                end else begin
                    if (N_id_2_valid_i) begin
                        $display("frame_sync: ignoring SSB outside FIND mode");
                    end
                    if (s_axis_in_tvalid) begin
                        if ((sample_cnt == FFT_LEN + current_CP_len - FIND_SAMPLES_TOLERANCE) && (syms_since_last_SSB == (SYMS_BTWN_SSB - 1))) begin
                            find_SSB <= 1;  // go into find state one SC before the symbol ends
                            // $display("find SSB ...");
                        end
                    end                    
                end

                if (N_id_2_valid_i && find_SSB) SSB_start_o <= '1;
                else                            SSB_start_o <= '0;

                out_valid <= s_axis_in_tvalid;

                // set sfn, subframe_number, sym_cnt, sample_cnt
                // set out_last
                if (s_axis_in_tvalid) begin
                    out_last <= sample_cnt == (FFT_LEN + current_CP_len - 2);

                    if (end_of_symbol) begin
                        if ((sym_cnt_next == 0) || (sym_cnt_next == 7))     current_CP_len <= CP1_LEN;
                        else                                                current_CP_len <= CP2_LEN;
                        
                        if (find_SSB && N_id_2_valid_i) syms_since_last_SSB <= '0;
                        else                            syms_since_last_SSB <= syms_since_last_SSB + 1;
                    end
                    sample_cnt <= sample_cnt_next;
                    sym_cnt <= sym_cnt_next;
                    subframe_number <= subframe_number_next;
                    sfn <= sfn_next;
                end else if (N_id_2_valid_i) begin
                    $display("Error: N_id_2_valid_i is out of sync with s_axis_in_tvalid!");
                    $finish();
                end
            end
        endcase
    end
end

// ----------------------------------------------------------------
// This process sets symbol_start_o to 1 at the beginning of every symbol,
// but only when the FSM above is in SYNCED state
reg symbol_state;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        symbol_start_o <= '0;
        symbol_state <= '0;
    end else begin
        case (symbol_state)
            0: begin
                // first symbol of SSB can arrive a bit earlier or later,
                // therefore need a special check for this case
                if (find_SSB) begin
                    if ((state != WAIT_FOR_SSB) && N_id_2_valid_i) begin
                        symbol_state <= 1;
                        symbol_start_o <= 1;
                    end
                end else begin
                    if ((state != WAIT_FOR_SSB) && (sample_cnt == 0) && (s_axis_in_tvalid)) begin
                        symbol_state <= 1;
                        symbol_start_o <= 1;
                    end
                end
            end
            1: begin
                symbol_start_o <= '0;
                if ((sample_cnt == 1) || (state == WAIT_FOR_SSB)) symbol_state <= '0;
            end
        endcase
    end
end

// store sample_id into FIFO at the beginning of each symbol
assign sample_id_valid = symbol_start_o;

receiver_regmap #(
    .ID(0),
    .ADDRESS_WIDTH(AXI_ADDRESS_WIDTH)
)
receiver_regmap_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),

    .fs_state_i(state),
    .rx_signal_i(),
    .N_id_2_i(),
    .N_id_i(),
    .sample_cnt_mismatch_i(sample_cnt_mismatch),
    .missed_SSBs_i(missed_SSBs),
    .ibar_SSB_i(ibar_SSB),
    .clks_btwn_SSBs_i(clks_btwn_SSBs),
    .num_disconnects_i(num_disconnects),
    .N_id_used_i(),

    .s_axi_if_awaddr(s_axi_awaddr),
    .s_axi_if_awvalid(s_axi_awvalid),
    .s_axi_if_awready(s_axi_awready),
    .s_axi_if_wdata(s_axi_wdata),
    .s_axi_if_wstrb(s_axi_wstrb),
    .s_axi_if_wvalid(s_axi_wvalid),
    .s_axi_if_wready(s_axi_wready),
    .s_axi_if_bresp(s_axi_bresp),
    .s_axi_if_bvalid(s_axi_bvalid),
    .s_axi_if_bready(s_axi_bready),
    .s_axi_if_araddr(s_axi_araddr),
    .s_axi_if_arvalid(s_axi_arvalid),
    .s_axi_if_arready(s_axi_arready),
    .s_axi_if_rdata(s_axi_rdata),
    .s_axi_if_rresp(s_axi_rresp),
    .s_axi_if_rvalid(s_axi_rvalid),
    .s_axi_if_rready(s_axi_rready)
);

endmodule
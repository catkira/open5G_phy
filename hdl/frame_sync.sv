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
    localparam USER_WIDTH = SFN_WIDTH + SUBFRAME_NUMBER_WIDTH + SYMBOL_NUMBER_WIDTH + $clog2(MAX_CP_LEN)
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

    output  reg        [OUT_DW - 1 : 0]             m_axis_out_tdata,
    output  reg        [USER_WIDTH - 1 : 0]         m_axis_out_tuser,
    output  reg                                     m_axis_out_tlast,
    output  reg                                     m_axis_out_tvalid,
    output  reg                                     symbol_start_o,
    output  reg                                     SSB_start_o
);

reg [$clog2(MAX_CP_LEN) - 1: 0] CP_len;
reg [SFN_WIDTH - 1 : 0] sfn;
reg [SUBFRAME_NUMBER_WIDTH - 1 : 0] subframe_number;
reg [SYMBOL_NUMBER_WIDTH - 1 : 0] sym_cnt;
reg [$clog2(MAX_CP_LEN) - 1 : 0] current_CP_len;
reg [IN_DW - 1 : 0] s_axis_in_tdata_f;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
        m_axis_out_tuser <= '0;
        s_axis_in_tdata_f <= '0;
    end else begin
        s_axis_in_tdata_f <= s_axis_in_tdata;
        m_axis_out_tdata <= s_axis_in_tdata_f;
        m_axis_out_tuser <= {sfn, subframe_number, sym_cnt, current_CP_len};
    end
end

always @(posedge clk_i) begin
    if (!reset_ni)  requested_N_id_2_o <= '0;
    else if (N_id_2_valid_i)  requested_N_id_2_o <= N_id_2_i;
end


// ---------------------------------------------------------------------------------------------------//
// FSM for controlling PSS detector
localparam [1 : 0] PSS_DETECTOR_MODE_SEARCH = 0;
localparam [1 : 0] PSS_DETECTOR_MODE_FIND   = 1;
localparam [1 : 0] PSS_DETECTOR_MODE_PAUSE  = 1;
localparam CLKS_20MS = $rtoi(CLK_FREQ * 0.02);
localparam CLKS_PSS_EARLY_WAKEUP = $rtoi(CLK_FREQ * 0.0001); // start PSS detector 0.1 ms before expected SSB
localparam CLKS_PSS_LATE_TOLERANCE = $rtoi(CLK_FREQ * 0.0001); // keep PSS detector running until 0.1ms after expected SSB
reg [$clog2(CLKS_20MS + CLKS_PSS_LATE_TOLERANCE) - 1 : 0] clks_since_SSB;
reg [1 : 0] PSS_state;
localparam [1 : 0] SEARCH_PSS = 0;
localparam [1 : 0] FIND_PSS = 1;
localparam [1 : 0] PAUSE_PSS = 2;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        PSS_state <= SEARCH_PSS;
        clks_since_SSB <= '0;
        PSS_detector_mode_o <= '0;
    end else begin
        PSS_detector_mode_o <= PSS_state;
        case (PSS_state)
            SEARCH_PSS : begin  // search PSS with any N_id_2
                if (N_id_2_valid_i) begin
                    PSS_state <= PAUSE_PSS;
                    clks_since_SSB <= 1;
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
                    $display("did not find PSS, going back to SEARCH mode!");
                    PSS_state <= SEARCH_PSS;
                end else if (N_id_2_valid_i) begin
                    $display("found PSS in FIND mode, putting PSS detectore in PAUSE mode");
                    PSS_state <= PAUSE_PSS;
                    clks_since_SSB <= 1;
                end else begin
                    clks_since_SSB <= clks_since_SSB + 1;
                end
            end
        endcase
    end
end


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
localparam [1 : 0] WAIT_FOR_SSB = 0;
localparam [1 : 0] WAIT_FOR_IBAR = 1;
localparam [1 : 0] SYNCED = 2;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        sfn <= '0;
        subframe_number <= '0;
        sym_cnt = '0;
        sample_cnt <= '0;
        state <= WAIT_FOR_SSB;
        current_CP_len <= CP2_LEN;
        find_SSB <= '0;
        symbol_start_o <= '0;
        SSB_start_o <= '0;
        syms_since_last_SSB <= '0;
        m_axis_out_tvalid <= '0;
        m_axis_out_tlast <= '0;
    end else begin
        case (state)
            WAIT_FOR_SSB: begin
                if (N_id_2_valid_i) begin
                    sample_cnt <= 1;
                    m_axis_out_tvalid <= s_axis_in_tvalid;
                    // SSB_pattern for case A is [2, 8, 16, 22]
                    // whether we are on symbol 3 or symbol 9 depends on ibar_SSB
                    // assume for now that we are at symbol 3
                    // it might have to be corrected once ibar_SSB arrives
                    current_CP_len <= CP2_LEN;
                    sym_cnt = 3;
                    state <= WAIT_FOR_IBAR;
                    syms_since_last_SSB <= '0;
                    SSB_start_o <= 1;
                end else begin
                    SSB_start_o <= '0;
                    m_axis_out_tvalid <= '0;
                end
            end
            WAIT_FOR_IBAR: begin
                if (ibar_SSB_valid_i) begin
                    $display("frame_sync: received ibar_SSB = %d", ibar_SSB_i);
                    if (ibar_SSB_i != 0) begin
                        // sym_cnt needs to be corrected for ibar_SSB != 0
                        case (ibar_SSB_i)
                            0: begin 
                                // no adjustment needed here
                            end
                            1: begin
                                sym_cnt = sym_cnt + 6 < SYM_PER_SF ? sym_cnt + 6 : sym_cnt + 6 - SYM_PER_SF;
                            end
                            2: begin
                                sym_cnt = sym_cnt + 14 < SYM_PER_SF ? sym_cnt + 6 : sym_cnt + 6 - SYM_PER_SF;
                                if (subframe_number == SUBFRAMES_PER_FRAME - 1) begin
                                    subframe_number <= '0;
                                    // inc sfn with modulo SFN_MAX if current subframe_number is SYM_PER_SF - 1
                                    sfn <= sfn == SFN_MAX - 1 ? 0 : sfn + 1;
                                end else begin
                                    subframe_number <= subframe_number + 1;
                                end                            end
                            3: begin
                                sym_cnt = sym_cnt + 20 < SYM_PER_SF ? sym_cnt + 6 : sym_cnt + 6 - SYM_PER_SF;
                                if (subframe_number == SUBFRAMES_PER_FRAME - 1) begin
                                    subframe_number <= '0;
                                    // inc sfn with modulo SFN_MAX if current subframe_number is SYM_PER_SF - 1
                                    sfn <= sfn == SFN_MAX - 1 ? 0 : sfn + 1;
                                end else begin
                                    subframe_number <= subframe_number + 1;
                                end
                            end
                        endcase
                    end
                    state <= SYNCED;
                end

                m_axis_out_tvalid <= s_axis_in_tvalid;

                if (s_axis_in_tvalid) begin
                    if (sample_cnt == (FFT_LEN + current_CP_len - 1)) begin
                        m_axis_out_tlast <= 1;

                        if (sym_cnt == SYM_PER_SF - 1) begin
                            sym_cnt = 0;
                            subframe_number <= subframe_number == SYM_PER_SF - 1 ? 0 : subframe_number + 1;
                            if (subframe_number == SUBFRAMES_PER_FRAME - 1) begin
                                subframe_number <= '0;
                                // inc sfn with modulo SFN_MAX if current subframe_number is SYM_PER_SF - 1
                                sfn <= sfn == SFN_MAX - 1 ? 0 : sfn + 1;
                            end else begin
                                subframe_number <= subframe_number + 1;
                            end
                        end else begin
                            sym_cnt = sym_cnt + 1;
                        end

                        sample_cnt <= '0;
                        if ((sym_cnt == 0) || (sym_cnt == 7))   current_CP_len <= CP1_LEN;
                        else                                    current_CP_len <= CP2_LEN;
                        
                        if ((syms_since_last_SSB == SYMS_BTWN_SSB - 1) || N_id_2_valid_i)   syms_since_last_SSB <= 0;
                        else                                            syms_since_last_SSB <= syms_since_last_SSB + 1;                        
                    end else begin
                        sample_cnt <= sample_cnt + 1;
                        m_axis_out_tlast <= '0;
                    end
                end else if (N_id_2_valid_i) begin
                    syms_since_last_SSB <= 0;                    
                end

                if (N_id_2_valid_i) begin
                    // output of SSB_start_o in WAIT_FOR_IBAR state is needed, because channel_estimator needs it to detect ibar_SSB
                    SSB_start_o <= 1;
                end else begin
                    SSB_start_o <= '0;
                end                
            end
            SYNCED: begin  // synced
                if (ibar_SSB_valid_i) begin
                    // TODO throw error if ibar_SSB does not match expected ibar_SSB
                end

                if (find_SSB) begin
                    if (N_id_2_valid_i) begin
                        // expected sample_cnt is 0, if actual sample_cnt deviates +-1, perform realignment
                        if (sample_cnt == 0) begin
                            // SSB arrives as expected, no STO correction needed
                            $display("SSB is on time");
                        end else if (sample_cnt < 2) begin
                            // SSB arrives too late
                            // correct this STO by outputting symbol_start and SSB_start a bit later
                            $display("SSB is late");
                        end else if (sample_cnt > (FFT_LEN + current_CP_len - 2)) begin
                            // SSB arrives too early
                            // correct this STO by outputting symbol_start and SSB_start a bit earlier
                            $display("SSB is early");
                        end
                        find_SSB <= '0;
                    end

                    if (sample_cnt == 3) begin
                        // could not find SSB, connection is lost 
                        // go back to search mode (state 0)
                        $display("could not find SSB, connection is lost!");
                        find_SSB <= '0;
                        state <= WAIT_FOR_SSB;
                    end
                end else begin
                    if (N_id_2_valid_i) begin
                        $display("ignoring SSB");
                    end
                end

                if (N_id_2_valid_i && find_SSB) SSB_start_o <= '1;
                else                            SSB_start_o <= '0;

                // set m_axis_out_tvalid
                if (find_SSB) begin
                    if (N_id_2_valid_i)                                     m_axis_out_tvalid <= s_axis_in_tvalid;
                    else if (sample_cnt > (FFT_LEN + current_CP_len - 2))   m_axis_out_tvalid <= s_axis_in_tvalid;
                    else                                                    m_axis_out_tvalid <= '0;
                end else begin
                    if (s_axis_in_tvalid) begin
                        if ((sample_cnt == FFT_LEN + current_CP_len - 2) && (syms_since_last_SSB == (SYMS_BTWN_SSB - 1))) begin
                            find_SSB <= 1;  // go into find state one SC before the symbol ends
                            $display("find SSB ...");
                        end
                    end
                    m_axis_out_tvalid <= s_axis_in_tvalid;
                end

                // set sfn, subfram_number, sym_cnt, sample_cnt
                // set m_axis_out_tlast
                if (s_axis_in_tvalid) begin
                    if (sample_cnt == (FFT_LEN + current_CP_len - 1)) begin
                        m_axis_out_tlast <= 1;
                        if (sym_cnt == SYM_PER_SF - 1) begin
                            sym_cnt = 0;
                            subframe_number <= subframe_number == SYM_PER_SF - 1 ? 0 : subframe_number + 1;
                            if (subframe_number == SUBFRAMES_PER_FRAME - 1) begin
                                subframe_number <= '0;
                                // inc sfn with modulo SFN_MAX if current subframe_number is SYM_PER_SF - 1
                                sfn <= sfn == SFN_MAX - 1 ? 0 : sfn + 1;
                            end else begin
                                subframe_number <= subframe_number + 1;
                            end
                        end else begin
                            sym_cnt = sym_cnt + 1;
                        end

                        sample_cnt <= '0;
                        if ((sym_cnt == 0) || (sym_cnt == 7))   current_CP_len <= CP1_LEN;
                        else                                    current_CP_len <= CP2_LEN;
                        
                        if (N_id_2_valid_i) syms_since_last_SSB <= '0;
                        else                syms_since_last_SSB <= syms_since_last_SSB + 1;
                    end else begin
                        sample_cnt <= sample_cnt + 1;
                        m_axis_out_tlast <= '0;
                    end
                end else if (N_id_2_valid_i) begin
                    syms_since_last_SSB <= '0;
                end
            end
        endcase
    end
end

endmodule
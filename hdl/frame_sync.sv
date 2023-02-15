`timescale 1ns / 1ns

module frame_sync #(
    parameter IN_DW = 32,
    localparam OUT_DW = IN_DW,
    localparam MAX_CP_LEN = 20
)
(
    input                                           clk_i,
    input                                           reset_ni,
    input   wire       [IN_DW - 1 : 0]              s_axis_in_tdata,
    input                                           s_axis_in_tvalid,

    input                                           SSB_start_i,
    input              [2 : 0]                      ibar_SSB_i,
    input                                           ibar_SSB_valid_i,

    output  reg        [OUT_DW - 1 : 0]             m_axis_out_tdata,
    output  reg                                     m_axis_out_tvalid,
    output  reg        [$clog2(MAX_CP_LEN) - 1: 0]  CP_len_o,
    output  reg                                     symbol_start_o,
    output  reg                                     PBCH_start_o,
    output  reg                                     SSS_start_o
);

localparam SFN_MAX = 20;
localparam SYM_PER_SF = 14;
localparam FFT_LEN = 256;
localparam CP1_LEN = 20;
localparam CP2_LEN = 18;
reg [$clog2(SFN_MAX) -1 : 0] sfn;
reg [$clog2(2*SYM_PER_SF) - 1 : 0] sym_cnt;
reg [$clog2(2*SYM_PER_SF) - 1 : 0] expected_SSB_sym;
reg [3 : 0] state;
reg [$clog2(FFT_LEN + MAX_CP_LEN) - 1 : 0] SC_cnt;
reg [$clog2(MAX_CP_LEN) - 1 : 0] current_CP_len;
reg find_SSB;

localparam SYMS_BTWN_SSB = 14 * 20;
reg [$clog2(SYMS_BTWN_SSB) - 1 : 0] syms_to_next_SSB;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
        m_axis_out_tvalid <= '0;
    end else begin
        m_axis_out_tdata <= s_axis_in_tdata;
        m_axis_out_tvalid <= s_axis_in_tvalid;
    end
end

always @(posedge clk_i) begin
    if (!reset_ni) begin
        sfn <= '0;
        sym_cnt = '0;
        SC_cnt <= '0;
        state <= '0;
        current_CP_len <= CP2_LEN;
        expected_SSB_sym <= '0;
        find_SSB <= '0;
        symbol_start_o <= '0;
        PBCH_start_o <= '0;
        SSS_start_o <= '0;
        syms_to_next_SSB <= '0;
    end else begin
        case (state)
            0: begin    // wait for SSB_start
                if (SSB_start_i) begin
                    SC_cnt <= 1;
                    // whether we are on symbol 3 or symbol 9 depends on ibar_SSB
                    // assume for now that we are at symbol 3
                    // it might have to be corrected once ibar_SSB arrives
                    current_CP_len <= CP2_LEN;
                    sym_cnt = 3;
                    expected_SSB_sym <= 3;
                    state <= 1;
                    syms_to_next_SSB <= '0;
                    PBCH_start_o <= 1;
                end else begin
                    PBCH_start_o <= '0;
                end
            end        // wait for ibar_SSB
            1: begin
                PBCH_start_o <= '0;
                if (ibar_SSB_valid_i) begin
                    if (ibar_SSB_i != 0) begin
                        // sym_cnt needs to be corrected for ibar_SSB != 0
                        if (ibar_SSB_i == 1)        sym_cnt = sym_cnt + 6;
                        else if (ibar_SSB_i == 2)   sym_cnt = sym_cnt + 14;
                        else if (ibar_SSB_i == 3)   sym_cnt = sym_cnt + 20;

                        if (sym_cnt >= SYM_PER_SF) begin  // perform modulo SYM_PER_SF operation
                            sym_cnt = sym_cnt - SYM_PER_SF;
                        end
                    end
                    state <= 2;
                end

                if (SSB_start_i) $display("unexpected SSB_start in state 1 !");

                if (s_axis_in_tvalid) begin
                    if (SC_cnt == (FFT_LEN + current_CP_len - 1)) begin
                        sym_cnt = sym_cnt + 1;
                        if (sym_cnt >= SYM_PER_SF) begin  // perform modulo SYM_PER_SF operation
                            sym_cnt = sym_cnt - SYM_PER_SF;
                        end

                        SC_cnt <= '0;
                        if ((sym_cnt == 0) || (sym_cnt == 7))   current_CP_len <= CP1_LEN;
                        else                                    current_CP_len <= CP2_LEN;
                        syms_to_next_SSB <= syms_to_next_SSB + 1;                        
                    end else begin
                        SC_cnt <= SC_cnt + 1;
                    end
                end
            end
            2: begin  // synced
                if (ibar_SSB_valid_i) begin
                    // TODO throw error if ibar_SSB does not match expected ibar_SSB
                end

                if (find_SSB) begin
                    if (SSB_start_i) begin
                        // expected SC_cnt is 0, if actual SC_cnt deviates +-1, perform realignment
                        if (SC_cnt == 0) begin
                            // SSB arrives as expected, no STO correction needed
                            $display("SSB is on time");
                        end else if (SC_cnt < 2) begin
                            // SSB arrives too late
                            // correct this STO by outputting symbol_start and PBCH_start a bit later
                            $display("SSB is late");
                        end else if (SC_cnt > (FFT_LEN + current_CP_len - 2)) begin
                            // SSB arrives too early
                            // correct this STO by outputting symbol_start and PBCH_start a bit earlier
                            $display("SSB is early");
                        end
                        find_SSB <= '0;
                    end

                    if (SC_cnt == 3) begin
                        // could not find SSB, connection is lost 
                        // go back to search mode (state 0)
                        $display("could not find SSB, connection is lost!");
                        find_SSB <= '0;
                        state <= 0;
                    end
                end else begin
                    if (SSB_start_i) begin
                        $display("ignoring SSB");
                    end
                end

                if (SSB_start_i && find_SSB)  PBCH_start_o <= '1;
                else                          PBCH_start_o <= '0;

                if (s_axis_in_tvalid) begin
                    if (SC_cnt == (FFT_LEN + current_CP_len - 1)) begin
                        sym_cnt = sym_cnt + 1;
                        if (sym_cnt >= SYM_PER_SF) begin  // perform modulo SYM_PER_SF operation
                            sym_cnt = sym_cnt - SYM_PER_SF;
                        end

                        SC_cnt <= '0;
                        if ((sym_cnt == 0) || (sym_cnt == 7))   current_CP_len <= CP1_LEN;
                        else                                    current_CP_len <= CP2_LEN;
                        syms_to_next_SSB <= syms_to_next_SSB + 1;
                    end else begin
                        SC_cnt <= SC_cnt + 1;
                    end

                    if ((SC_cnt == FFT_LEN + current_CP_len - 2) && (syms_to_next_SSB == (SYMS_BTWN_SSB - 1))) begin
                        find_SSB <= 1;
                        $display("find SSB ...");
                    end
                end
            end
        endcase
    end
end

// `ifdef COCOTB_SIM
// initial begin
//   $dumpfile ("debug.vcd");
//   $dumpvars (0, frame_sync);
// end
// `endif

endmodule
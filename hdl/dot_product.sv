`timescale 1ns / 1ns

module dot_product
#(
    parameter A_DW = 1,               // input a data width
    parameter B_DW = 32,               // input b data width
    parameter OUT_DW = 8,              // output data width
    parameter LEN = 128,               // len
    parameter A_COMPLEX = 0,           // is input a complex?
    parameter B_COMPLEX = 1            // is input b complex?
)
(
    input                                       clk_i,
    input                                       reset_ni,
    input                                       start_i,
    input   wire           [A_DW-1:0]           s_axis_a_tdata,
    input                                       s_axis_a_tvalid,
    output  reg                                 s_axis_a_tready,
    input   wire           [B_DW-1:0]           s_axis_b_tdata,
    input                                       s_axis_b_tvalid,
    output  reg            [OUT_DW-1:0]         result_o,
    output  reg                                 valid_o
);

localparam REAL_COMPLEX = (A_COMPLEX != B_COMPLEX);
localparam COMPLEX_DW = A_COMPLEX ? A_DW : B_DW;
localparam REAL_DW = A_COMPLEX ? B_DW : A_DW;
wire [COMPLEX_DW - 1 : 0] complex_in;
assign complex_in = A_COMPLEX ? s_axis_a_tdata : s_axis_b_tdata;
wire signed [COMPLEX_DW / 2 - 1 : 0] complex_in_re, complex_in_im;
assign complex_in_re = complex_in[COMPLEX_DW / 2 - 1 : 0];
assign complex_in_im = complex_in[COMPLEX_DW - 1 : COMPLEX_DW / 2];
wire [REAL_DW - 1 : 0] real_in;
assign real_in = B_COMPLEX ? s_axis_a_tdata : s_axis_b_tdata;

initial begin
    $display("REAL_COMPLEX = %d", REAL_COMPLEX);
    $display("A_DW = %d   B_DW = %d", A_DW, B_DW);
end

reg signed [OUT_DW : 0] acc; // user needs to make sure no overflow happens !
reg signed [OUT_DW / 2 - 1 : 0] acc_re, acc_im;

reg [10 : 0] state;
reg [$clog2(LEN) : 0] cnt;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        $display("RESET");
        acc <= '0;
        acc_re <= '0;
        acc_im <= '0;
        result_o <= '0;
        valid_o <= '0;
        state <= 0;
        s_axis_a_tready <= '0;
    end else begin
        if (state == 0) begin  // perform multiply adds
            if (cnt == LEN - 1) begin
                state <= 1;
                valid_o <= 1'b1;
                if (REAL_COMPLEX) begin
                    result_o <= {acc_im, acc_re};
                end else begin
                    // TODO: implement
                end
            end else if (s_axis_a_tvalid) begin
                state <= 0;
                valid_o <= '0;
                // perform multiply adds
                // $display("cnt = %d  complex_in_re = %d acc_re = %d acc_im = %d", cnt, complex_in_re, acc_re, acc_im);
                if (start_i) begin
                    cnt <= '0;
                    if(REAL_COMPLEX) begin
                        if(REAL_DW == 1) begin // one input is signed boolean
                            if (real_in == 1) begin
                                acc_re <= complex_in_re;
                                acc_im <= complex_in_im;
                            end else begin
                                acc_re <= complex_in_re;
                                acc_im <= complex_in_im;
                            end
                        end else begin
                            // TODO: implement
                        end
                    end else begin
                        // TODO: implement
                    end
                end else begin
                    cnt <= cnt + 1;
                    if(REAL_COMPLEX) begin
                        if(REAL_DW == 1) begin // one input is signed boolean
                            if (real_in == 1) begin
                                acc_re <= acc_re + complex_in_re;
                                acc_im <= acc_im + complex_in_im;
                            end else begin
                                acc_re <= acc_re - complex_in_re;
                                acc_im <= acc_im - complex_in_im;
                            end
                        end else begin
                            // TODO: implement
                        end
                    end else begin
                        // TODO: implement
                    end
                end
            end
        end else if (state == 1) begin  // output result
            state <= '0;
            s_axis_a_tready <= '1;
            valid_o <= '0;
            cnt <= '0;
        end
        else begin  //  should never happen
            // $display("ERROR state = %d", state);
        end
    end
end
endmodule
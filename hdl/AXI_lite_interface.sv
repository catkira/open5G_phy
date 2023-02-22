`timescale 1ns / 1ns
// This core encapsulates a AXI lite slave interface and provides a simple core interface
// Copyright (C) 2023  Benjamin Menkuec
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.


// This core encapsulates a AXI lite slave interface and provides a simple core interface
// 
// The simple client core interface can be used to write or write to specific addresses.
// The size of each read or write is fixed 4 byte.
// This core will wait for 16 clks to receive a rack or wack from the client core,
// if it does not receive one, it will ack anyway.

module AXI_lite_interface #(
    parameter   ADDRESS_WIDTH = 16
)
(
    // reset and clocks
    input                                       reset_ni,
    input                                       clk_i,

    // AXI lite interface
    // write address channel
    input           [ADDRESS_WIDTH - 1 : 0]     s_axi_awaddr,
    input                                       s_axi_awvalid,
    output  reg                                 s_axi_awready,
    
    // write data channel
    input           [31 : 0]                    s_axi_wdata,
    input           [ 3 : 0]                    s_axi_wstrb,      // not used
    input                                       s_axi_wvalid,
    output  reg                                 s_axi_wready,

    // write response channel
    output          [ 1 : 0]                    s_axi_bresp,
    output  reg                                 s_axi_bvalid,
    input                                       s_axi_bready,

    // read address channel
    input           [ADDRESS_WIDTH - 1 : 0]     s_axi_araddr,
    input                                       s_axi_arvalid,
    output  reg                                 s_axi_arready,

    // read data channel
    output  reg     [31 : 0]                    s_axi_rdata,
    output          [ 1 : 0]                    s_axi_rresp,
    output  reg                                 s_axi_rvalid,
    input                                       s_axi_rready,

    // core interface
    output  reg                                 wreq_o,
    output  reg     [ADDRESS_WIDTH - 3 : 0]     waddr_o,
    output  reg     [31 : 0]                    wdata_o,
    input                                       wack,
    output  reg                                 rreq_o,
    output  reg     [ADDRESS_WIDTH - 3 : 0]     raddr_o,
    input           [31 : 0]                    rdata,
    input                                       rack
);

    // internal registers
    reg                                 wack_f;
    reg                                 wsel;
    reg     [ 4 : 0]                    wcount;
    reg                                 rack_f;
    reg     [31 : 0]                    rdata_f;
    reg                                 rsel;
    reg     [ 4 : 0]                    rcount;

    // internal signals
    wire                                wack_w;
    wire                                rack_w;
    wire    [31 : 0]                    rdata_s;

    // write channel interface
    assign axi_bresp = 2'd0;

    always @(posedge clk_i) begin
        if (!reset_ni) begin
            s_axi_awready <= '0;
            s_axi_wready <= '0;
            s_axi_bvalid <= '0;
        end else begin
            if (s_axi_awready)  s_axi_awready <= 1'b0;   // keep axi_awready only high for 1 cycle
            else if (wack_w)    s_axi_awready <= 1'b1;   // ready to receive write addr

            if (s_axi_wready)   s_axi_wready <= 1'b0;    // keep axi_wready only high for 1 cycle
            else if (wack_w)    s_axi_wready <= 1'b1;    // ready to receive data

            if (s_axi_bready && s_axi_bvalid)   s_axi_bvalid <= 1'b0;
            else if (wack_f)                    s_axi_bvalid <= 1'b1;     // write response
        end
    end

    // wait 16 clks to receive wack from client core, otherwise this core will ack it anyway
    assign wack_w = (wcount == 5'h1f) ? 1'b1 : (wcount[4] & wack);

    always @(posedge clk_i) begin
        if (!reset_ni) begin
            wack_f <= '0;
            wsel <= '0;
            wreq_o <= '0;
            waddr_o <= '0;
            wdata_o <= '0;
            wcount <= '0;
        end else begin
            wack_f <= wack_w;
            if (wsel) begin
                if (s_axi_bready && s_axi_bvalid) wsel <= 1'b0;     // clear wsel if response handshake happened
                wreq_o <= 1'b0;
            end else begin
                wsel <= s_axi_awvalid & s_axi_wvalid;               // set wsel if write address and write handshake happened
                wreq_o <= s_axi_awvalid & s_axi_wvalid;             // signal write request to core
                waddr_o <= s_axi_awaddr[(ADDRESS_WIDTH-1):2];       // signal address of write request to core
                wdata_o <= s_axi_wdata;                             // signal data of write request to core
            end

            if (wack_w)         wcount <= 5'h00;                // reset wcount if ready to receive write request
            else if (wcount[4]) wcount <= wcount + 1'b1;        // inc wcount if write request is active
            else if (wreq_o)    wcount <= 5'h10;                // set wcount = 0x10 if write request just started
        end
    end

    // read channel interface
    assign s_axi_rresp = 2'd0;

    always @(posedge clk_i) begin
        if (!reset_ni) begin
            s_axi_arready <= '0;
            s_axi_rvalid <= '0;
            s_axi_rdata <= '0;
        end else begin
            if (s_axi_arready)    s_axi_arready <= 1'b0;
            else if (rack_w)      s_axi_arready <= 1'b1;

            if (s_axi_rready && s_axi_rvalid) begin
                s_axi_rvalid <= 1'b0;
                s_axi_rdata <= 32'd0;
            end else if (rack_f) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rdata <= rdata_f;
            end
        end
    end

    // if rack does not arrive within 16 clks from client core, this core will rack anyway
    assign rack_w = (rcount == 5'h1f) ? 1'b1 : (rcount[4] & rack);
    // if rack did not come from client core, received data will be 'dead'
    assign rdata_s = (rcount == 5'h1f) ? {2{16'hdead}} : rdata;

    always @(posedge clk_i) begin
        if (!reset_ni) begin
            rack_f <= '0;
            rdata_f <= '0;
            rsel <= '0;
            rreq_o <= '0;
            raddr_o <= '0;
            rcount <= '0;
        end else begin
            rack_f <= rack_w;
            rdata_f <= rdata_s;

            if (rsel) begin
                if (s_axi_rready && s_axi_rvalid) rsel <= 1'b0;
                rreq_o <= 1'b0;
            end else begin
                rsel <= s_axi_arvalid;
                rreq_o <= s_axi_arvalid;
                raddr_o <= s_axi_araddr[ADDRESS_WIDTH - 1 : 2];
            end

            if (rack_w)         rcount <= 5'h00;
            else if (rcount[4]) rcount <= rcount + 1'b1;
            else if (rreq_o)    rcount <= 5'h10;
        end
    end

endmodule
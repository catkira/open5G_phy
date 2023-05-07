module axis_axil_fifo #(
    parameter ID = 0,    
    parameter DATA_WIDTH = 16,
    parameter FIFO_LEN = 8,      // has to be power of 2 !
    parameter USER_WIDTH = 1,
    parameter ADDRESS_WIDTH = 16    
)
(
    input                                               clk_i,
    input                                               reset_ni,
    input                                               clear_i,

    input           [DATA_WIDTH - 1 : 0]                s_axis_in_tdata,
    input           [USER_WIDTH - 1 : 0]                s_axis_in_tuser,
    input                                               s_axis_in_tlast,
    input                                               s_axis_in_tvalid,
    output  reg                                         s_axis_in_tfull,

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
    input                                       s_axi_rready    
);

localparam PCORE_VERSION = 'h00010069;

reg [DATA_WIDTH - 1 : 0]    fifo_data;
reg [USER_WIDTH - 1 : 0]    fifo_user;
reg [31 : 0]                fifo_level;
reg                         fifo_ready;
reg                         fifo_valid;
reg                         fifo_empty;
reg                         fifo_last;

wire reset_fifo_n = reset_ni && (~clear_i);

AXIS_FIFO #(
    .DATA_WIDTH(DATA_WIDTH),
    .FIFO_LEN(FIFO_LEN),
    .USER_WIDTH(USER_WIDTH),
    .ASYNC(1'b0)
)
AXIS_FIFO_i(
    .clk_i(clk_i),
    .s_reset_ni(reset_fifo_n),

    .s_axis_in_tdata(s_axis_in_tdata),
    .s_axis_in_tuser(s_axis_in_tuser),
    .s_axis_in_tlast(s_axis_in_tlast),
    .s_axis_in_tvalid(s_axis_in_tvalid),
    .s_axis_in_tfull(s_axis_in_tfull),

    .out_clk_i(clk_i),
    .m_reset_ni(reset_ni),
    .m_axis_out_tready(fifo_ready),
    .m_axis_out_tdata(fifo_data),
    .m_axis_out_tuser(fifo_user),
    .m_axis_out_tlast(fifo_last),
    .m_axis_out_tvalid(fifo_valid),
    .m_axis_out_tlevel(fifo_level),
    .m_axis_out_tempty(fifo_empty)
);

wire rreq;
wire [ADDRESS_WIDTH - 3 : 0] raddr;
reg [31:0] rdata;
reg rack;

reg [1 : 0] state;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        rack <= '0;
        state <= '0;
    end else if (raddr == 7) begin
        case (state)
            0 : begin
                rack <= '0;
                if ((!fifo_empty) && rreq) begin // this will block forever if fifo is empty !
                    fifo_ready <= 1;
                    state <= 1;
                end
            end
            1 : begin
                fifo_ready <= '0;
                if (fifo_valid) begin
                    state <= 2;
                    rack <= 1;
                end
            end
            2 : begin
                rack <= '0;
                state <= '0;
            end
        endcase
    end else begin
        rack <= rreq;   // ack immediately after req
    end
end

always @(posedge clk_i) begin
    if (!reset_ni)  rdata <= '0;
    else begin
        if (rreq == 1'b1) begin
            case (raddr)
                9'h000: rdata <= PCORE_VERSION;
                9'h001: rdata <= ID;
                9'h002: rdata <= '0;
                9'h003: rdata <= 32'h4649464F; // "FIFO"
                9'h004: rdata <= 32'h69696969;

                9'h005: rdata <= fifo_level;
                9'h006: rdata <= fifo_empty;
                9'h007: rdata <= fifo_data;
                9'h008: rdata <= fifo_user;
                default: rdata <= '0;
            endcase
        end
    end
end

AXI_lite_interface #(
    .ADDRESS_WIDTH(ADDRESS_WIDTH)
)
AXI_lite_interface_i(
    .clk_i(clk_i),
    .reset_ni(reset_ni),

    .s_axi_awaddr(s_axi_awaddr),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),
    .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),

    .wreq_o(),
    .waddr_o(),
    .wdata_o(),
    .wack(),
    .rreq_o(rreq),
    .raddr_o(raddr),
    .rdata(rdata),
    .rack(rack)      
);

endmodule
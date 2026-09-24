`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/14/2026 02:52:43 AM
// Design Name: 
// Module Name: eth_capture_bridge_top
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module eth_capture_bridge_top(
  inout [14:0]DDR_addr,
  inout [2:0]DDR_ba,
  inout DDR_cas_n,
  inout DDR_ck_n,
  inout DDR_ck_p,
  inout DDR_cke,
  inout DDR_cs_n,
  inout [3:0]DDR_dm,
  inout [31:0]DDR_dq,
  inout [3:0]DDR_dqs_n,
  inout [3:0]DDR_dqs_p,
  inout DDR_odt,
  inout DDR_ras_n,
  inout DDR_reset_n,
  inout DDR_we_n,
  inout FIXED_IO_ddr_vrn,
  inout FIXED_IO_ddr_vrp,
  inout [53:0]FIXED_IO_mio,
  inout FIXED_IO_ps_clk,
  inout FIXED_IO_ps_porb,
  inout FIXED_IO_ps_srstb
);
    (* mark_debug = "true" *) logic [7:0] sniff_tdata;
    (* mark_debug = "true" *) logic sniff_tvalid, sniff_tlast;
    // DMA (M_AXIS_MM2S_0) -> axis_sync_fifo, write/slave side
    (* mark_debug = "true" *) logic [7:0] dma_axis_tdata;
    (* mark_debug = "true" *) logic dma_axis_tvalid, dma_axis_tready, dma_axis_tlast;
    // axis_sync_fifo -> axis_demux, read/master side
    (* mark_debug = "true" *) logic [7:0] fifo_axis_tdata;
    (* mark_debug = "true" *) logic fifo_axis_tvalid, fifo_axis_tready, fifo_axis_tlast;
    // axis_demux -> udp_sniffer, matched (dst port == 1234) frames only
    (* mark_debug = "true" *) logic [7:0] demux_matched_tdata;
    (* mark_debug = "true" *) logic demux_matched_tvalid, demux_matched_tready, demux_matched_tlast;
    // axis_demux -> sink, everything else. No downstream consumer yet,
    // so tready is tied high (never backpressures the FIFO). Kept
    // mark_debug so unmatched traffic (ARP/mDNS/etc.) is still visible
    // on the ILA for validation.
    (* mark_debug = "true" *) logic [7:0] demux_unmatched_tdata;
    (* mark_debug = "true" *) logic demux_unmatched_tvalid, demux_unmatched_tlast;
    // udp_sniffer -> itch_parser, parsed ITCH 5.0 message fields.
    // udp_sniffer's m_axis_tready is tied high (no backpressure) and
    // itch_parser's s_axis_tready is likewise always 1 internally, so
    // this link is trivially rate-matched, same as the sniffer's own
    // input side.
    (* mark_debug = "true" *) logic        itch_msg_valid;
    (* mark_debug = "true" *) logic [7:0]  itch_msg_type;
    (* mark_debug = "true" *) logic [15:0] itch_stock_locate;
    (* mark_debug = "true" *) logic [63:0] itch_order_ref;
    (* mark_debug = "true" *) logic        itch_buy_sell;
    (* mark_debug = "true" *) logic [31:0] itch_shares;
    (* mark_debug = "true" *) logic [31:0] itch_price;
    (* mark_debug = "true" *) logic [63:0] itch_match_num;
    logic fclk_clk0_ext;
    logic [0:0] peripheral_aresetn_ext;
    
    eth_block_wrapper dut1( 
        .DDR_addr(DDR_addr),
        .DDR_ba(DDR_ba),
        .DDR_cas_n(DDR_cas_n),
        .DDR_ck_n(DDR_ck_n),
        .DDR_ck_p(DDR_ck_p),
        .DDR_cke(DDR_cke),
        .DDR_cs_n(DDR_cs_n),
        .DDR_dm(DDR_dm),
        .DDR_dq(DDR_dq),
        .DDR_dqs_n(DDR_dqs_n),
        .DDR_dqs_p(DDR_dqs_p),
        .DDR_odt(DDR_odt),
        .DDR_ras_n(DDR_ras_n),
        .DDR_reset_n(DDR_reset_n),
        .DDR_we_n(DDR_we_n),
        .FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp),
        .FIXED_IO_mio(FIXED_IO_mio),
        .FIXED_IO_ps_clk(FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb(FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb),
        .M_AXIS_MM2S_0_tdata(dma_axis_tdata),
        .M_AXIS_MM2S_0_tkeep(),
        .M_AXIS_MM2S_0_tlast(dma_axis_tlast),
        .M_AXIS_MM2S_0_tready(dma_axis_tready),
        .M_AXIS_MM2S_0_tvalid(dma_axis_tvalid),
        .fclk_clk0_ext(fclk_clk0_ext),
        .peripheral_aresetn_ext(peripheral_aresetn_ext)
    );

    axis_sync_fifo #(
        .DATA_WIDTH(8),
        .DEPTH(16)
    ) dut3 (
        .clk(fclk_clk0_ext),
        .rst(~peripheral_aresetn_ext),
        // slave side: fed by the DMA
        .s_axis_tdata  (dma_axis_tdata),
        .s_axis_tlast  (dma_axis_tlast),
        .s_axis_tvalid (dma_axis_tvalid),
        .s_axis_tready (dma_axis_tready),
        // master side: feeds axis_demux
        .m_axis_tdata  (fifo_axis_tdata),
        .m_axis_tlast  (fifo_axis_tlast),
        .m_axis_tvalid (fifo_axis_tvalid),
        .m_axis_tready (fifo_axis_tready)
    );

    axis_demux #(
        .DATA_WIDTH  (8),
        .FIFO_DEPTH  (64),
        .TARGET_PORT (16'd1234)
    ) dut4 (
        .clk(fclk_clk0_ext),
        .rst(~peripheral_aresetn_ext),
        // slave side: fed by the FIFO (raw frames, headers included)
        .s_axis_tdata  (fifo_axis_tdata),
        .s_axis_tvalid (fifo_axis_tvalid),
        .s_axis_tready (fifo_axis_tready),
        .s_axis_tlast  (fifo_axis_tlast),
        // matched master: feeds udp_sniffer
        .m_axis_matched_tdata  (demux_matched_tdata),
        .m_axis_matched_tvalid (demux_matched_tvalid),
        .m_axis_matched_tready (demux_matched_tready),
        .m_axis_matched_tlast  (demux_matched_tlast),
        // unmatched master: no consumer yet, sunk below
        .m_axis_unmatched_tdata  (demux_unmatched_tdata),
        .m_axis_unmatched_tvalid (demux_unmatched_tvalid),
        .m_axis_unmatched_tready (1'b1),
        .m_axis_unmatched_tlast  (demux_unmatched_tlast)
    );

    udp_sniffer dut2(
        .clk(fclk_clk0_ext),
        .rst(~peripheral_aresetn_ext),
        .s_axis_tvalid (demux_matched_tvalid),
        .s_axis_tready (demux_matched_tready),
        .s_axis_tdata  (demux_matched_tdata),
        .s_axis_tlast  (demux_matched_tlast),
        .m_axis_tvalid (sniff_tvalid),
        .m_axis_tready (1'b1),
        .m_axis_tdata  (sniff_tdata),
        .m_axis_tlast  (sniff_tlast)
    );

    itch_parser dut5(
        .clk(fclk_clk0_ext),
        .rst(~peripheral_aresetn_ext),
        // slave side: fed directly by udp_sniffer's payload stream
        .s_axis_tdata  (sniff_tdata),
        .s_axis_tvalid (sniff_tvalid),
        .s_axis_tlast  (sniff_tlast),
        .s_axis_tready (),                 // unused: itch_parser always asserts tready internally
        .msg_valid     (itch_msg_valid),
        .msg_type      (itch_msg_type),
        .stock_locate  (itch_stock_locate),
        .order_ref     (itch_order_ref),
        .buy_sell      (itch_buy_sell),
        .shares        (itch_shares),
        .price         (itch_price),
        .match_num     (itch_match_num)
    );
endmodule

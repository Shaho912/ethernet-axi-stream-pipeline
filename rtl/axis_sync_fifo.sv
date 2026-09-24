`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/27/2026 05:47:10 PM
// Design Name: 
// Module Name: axis_sync_fifo
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


module axis_sync_fifo #(
    parameter DATA_WIDTH = 8,
    parameter DEPTH      = 16,
    parameter PTR_WIDTH  = $clog2(DEPTH) + 1
)(
    input  logic                   clk,
    input  logic                   rst,

    // Slave (write) side from DMA
    input  logic [DATA_WIDTH-1:0]  s_axis_tdata,
    input  logic                   s_axis_tlast,
    input  logic                   s_axis_tvalid,
    output logic                   s_axis_tready,

    // Master (read) side to udp_sniffer
    output logic [DATA_WIDTH-1:0]  m_axis_tdata,
    output logic                   m_axis_tlast,
    output logic                   m_axis_tvalid,
    input  logic                   m_axis_tready
);

    logic [DATA_WIDTH:0] mem [0:DEPTH-1];
    logic [PTR_WIDTH-1:0] re_ptr  = '0;
    logic [PTR_WIDTH-1:0] wr_ptr  = '0;
    logic full, empty;
    logic wr_en;
    logic re_en;
    
    
    assign empty = (re_ptr == wr_ptr);
    assign full = ((re_ptr[PTR_WIDTH-1] != wr_ptr[PTR_WIDTH-1]) && 
                    (re_ptr[PTR_WIDTH-2:0] == wr_ptr[PTR_WIDTH-2:0]));
                    
    assign s_axis_tready = ~full;
    assign m_axis_tvalid = ~empty;
    assign wr_en = s_axis_tvalid && ~full;
    assign re_en = m_axis_tvalid && m_axis_tready;
    
    always_ff @(posedge clk) begin
        if (rst) begin
            re_ptr <= '0;
            wr_ptr <= '0;
        end else begin
            if (wr_en) begin
                mem[wr_ptr[PTR_WIDTH-2:0]] <= {s_axis_tlast, s_axis_tdata};
                wr_ptr <= wr_ptr + 1;
            end
            if (re_en) begin
                re_ptr <= re_ptr + 1;   // pointer only — no more registering tdata here
            end
        end
    end

    assign {m_axis_tlast, m_axis_tdata} = mem[re_ptr[PTR_WIDTH-2:0]];
endmodule

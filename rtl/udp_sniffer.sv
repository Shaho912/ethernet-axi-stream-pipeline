`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/29/2026 08:32:03 PM
// Design Name: 
// Module Name: udp_sniffer
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

package udp_package;
    typedef enum logic [2:0] {
        IDLE = 3'b000,
        ETH_HEADER = 3'b001, 
        IP_HEADER = 3'b010, 
        UDP_HEADER = 3'b011, 
        PAYLOAD = 3'b100, 
        DISCARD = 3'b101
    } state_t;
endpackage

module udp_sniffer import udp_package::*;
    (
    input logic clk, input logic rst,
    input  logic        s_axis_tvalid,   // MAC has valid byte
    output logic        s_axis_tready,   // parser ready to receive
    input  logic [7:0]  s_axis_tdata,    // the byte
    input  logic        s_axis_tlast,    // last byte of packet
    
    output logic        m_axis_tvalid,   // parser has valid payload byte
    input  logic        m_axis_tready,   // downstream ready to receive
    output logic [7:0]  m_axis_tdata,    // payload byte
    output logic        m_axis_tlast     // last byte of payload
    );
    
    localparam [15:0] TARGET_PORT = 16'd1234;
    state_t state = IDLE;
    (* mark_debug = "true" *) logic [6:0] byte_count = '0;
    (* mark_debug = "true" *) logic [15:0] ethertype;
    (* mark_debug = "true" *) logic [7:0]  ip_protocol;
    (* mark_debug = "true" *) logic [3:0]  ip_ihl;
    (* mark_debug = "true" *) logic [15:0] dst_port;
    
    assign s_axis_tready = 1;
    assign m_axis_tvalid = (state == PAYLOAD) && s_axis_tvalid;
    assign m_axis_tdata = s_axis_tdata;
    assign m_axis_tlast = (state == PAYLOAD) && s_axis_tlast;
    
    always_ff@(posedge clk) begin
        if (rst) begin
            state      <= IDLE;
            byte_count <= '0;
            ethertype  <= '0;
            ip_protocol <= '0;
            ip_ihl     <= '0;
            dst_port   <= '0;
        end
        else if (s_axis_tready && s_axis_tvalid) begin
            if (s_axis_tlast) begin
                state      <= IDLE;
                byte_count <= '0;
                ethertype  <= '0;
                ip_protocol <= '0;
                ip_ihl     <= '0;
                dst_port   <= '0;
            end
            else begin 
                case (state)
                    IDLE: begin
                        byte_count <= 1;
                        state <= ETH_HEADER;
                    end
                    ETH_HEADER: begin
                        byte_count <= byte_count + 1;
                        if (byte_count == 12) begin
                            ethertype[15:8] <= s_axis_tdata;
                        end
                        if (byte_count == 13) begin
                            ethertype[7:0] <= s_axis_tdata;
                        end
                        if (byte_count == 14) begin
                            if (ethertype == 16'h0800) begin
                                    state <= IP_HEADER;
                                    ip_ihl <= s_axis_tdata[3:0];
                                end
                                else begin
                                    state <= DISCARD;
                                end
                        end
                    end
                    IP_HEADER: begin
                        byte_count <= byte_count + 1;
                        if (byte_count == 23) begin
                            ip_protocol <= s_axis_tdata;
                        end
                        if (byte_count == 24) begin
                                if (ip_protocol != 8'h11) begin
                                    state <= DISCARD;
                                end
                        end
                        if (byte_count == (13 + (ip_ihl << 2))) begin
                            state <= UDP_HEADER;
                        end
                    end
                    UDP_HEADER: begin
                        byte_count <= byte_count + 1;
                        if (byte_count == (16 + (ip_ihl << 2))) begin
                            dst_port[15:8] <= s_axis_tdata;
                        end
                        if (byte_count == (17 + (ip_ihl << 2))) begin
                            dst_port[7:0] <= s_axis_tdata;
                        end
                        if (byte_count == (18 + (ip_ihl << 2))) begin
                            if (dst_port != TARGET_PORT) begin
                                    state <= DISCARD;
                            end
                        end
                        if (byte_count == (21 + (ip_ihl << 2))) begin
                            state <= PAYLOAD;
                        end
                    end
                    PAYLOAD: begin
                        byte_count <= byte_count + 1;
                    end
                    DISCARD: begin
                        byte_count <= byte_count + 1;
                    end
                endcase
            end
        end
    end
endmodule

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 08/31/2026 10:31:59 AM
// Design Name:
// Module Name: itch_parser
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
package itch_msg_package;
    typedef enum logic [2:0] {
        IDLE = 3'b000,
        TYPE = 3'b001,
        HEADER = 3'b010,
        BODY = 3'b011,
        DONE = 3'b100
    } msg_t;
endpackage

module itch_parser import itch_msg_package::*;
(
    input logic clk, rst,
    input logic [7:0] s_axis_tdata,
    input logic s_axis_tvalid, s_axis_tlast,
    output s_axis_tready,

    output logic        msg_valid,      // 1-cycle pulse when a message is fully parsed
    output logic [7:0]   msg_type,       // 'A','F','E','X','D'
    output logic [15:0]  stock_locate,
    output logic [63:0]  order_ref,
    output logic         buy_sell,       // valid for A/F only
    output logic [31:0]  shares,
    output logic [31:0]  price,          // valid for A/F only
    output logic [63:0]  match_num       // valid for E only
    );

    logic [7:0] byte_count = '0;
    logic [6:0] msg_length;
    logic [6:0] bit_pos = 63;
    msg_t msg_state = IDLE;

    assign s_axis_tready = 1;

    always_ff@(posedge clk) begin
        msg_valid <= 0;
        if (rst) begin
            msg_state <= IDLE;
            byte_count <= '0;
            msg_valid <= '0;
            bit_pos <= 63;
        end
        else if (s_axis_tvalid && s_axis_tready) begin
            case (msg_state)
                IDLE: begin
                    byte_count <= byte_count + 1;
                    msg_type <= s_axis_tdata;
                    msg_state <= HEADER;
                    case(s_axis_tdata)
                        "A": begin
                            msg_length <= 36;
                        end
                        "F": begin
                            msg_length <= 40;
                        end
                        "E": begin
                            msg_length <= 31;
                        end
                        "X": begin
                            msg_length <= 23;
                        end
                        "D": begin
                            msg_length <= 19;
                        end
                    endcase
                end
                HEADER: begin
                    byte_count <= byte_count + 1;
                    if (byte_count == 1) begin
                        stock_locate[15:8] <= s_axis_tdata;
                    end
                    msg_state <= HEADER;
                    if (byte_count == 2) begin
                        stock_locate[7:0] <= s_axis_tdata;
                    end
                    if (byte_count == 10) begin
                        msg_state <= BODY;
                    end
                end
                BODY: begin
                    byte_count <= byte_count + 1;
                    case (msg_type)
                        "A": begin
                            if (byte_count >= 11 && byte_count <= 18) begin
                                order_ref[bit_pos -: 8] <= s_axis_tdata;;
                                if (byte_count == 18) begin
                                    bit_pos <= 31;
                                end
                                else begin
                                    bit_pos <= bit_pos - 8;
                                end
                            end
                            if (byte_count == 19) begin
                                buy_sell <= (s_axis_tdata == "B");;
                            end
                            if (byte_count >= 20 && byte_count <= 23) begin
                                shares[bit_pos -: 8] <= s_axis_tdata;;
                                if (byte_count == 23) begin
                                    bit_pos <= 31;
                                end
                                else begin
                                    bit_pos <= bit_pos - 8;
                                end
                            end
                            if (byte_count >= 32 && byte_count <= 35) begin
                                price[bit_pos -: 8] <= s_axis_tdata;;
                                bit_pos <= bit_pos - 8;
                            end
                        end
                        "F": begin
                            if (byte_count >= 11 && byte_count <= 18) begin
                                order_ref[bit_pos -: 8] <= s_axis_tdata;;
                                if (byte_count == 18) begin
                                    bit_pos <= 31;
                                end
                                else begin
                                    bit_pos <= bit_pos - 8;
                                end
                            end
                            if (byte_count == 19) begin
                                buy_sell <= (s_axis_tdata == "B");;
                            end
                            if (byte_count >= 20 && byte_count <= 23) begin
                                shares[bit_pos -: 8] <= s_axis_tdata;;
                                if (byte_count == 23) begin
                                    bit_pos <= 31;
                                end
                                else begin
                                    bit_pos <= bit_pos - 8;
                                end
                            end
                            if (byte_count >= 32 && byte_count <= 35) begin
                                price[bit_pos -: 8] <= s_axis_tdata;;
                                if (byte_count == 35) begin
                                    bit_pos <= 63;
                                end
                                else begin
                                    bit_pos <= bit_pos - 8;
                                end
                            end
//                            if (byte_count >= 36 && byte_count <= 39) begin
//                                mpid[bit_pos -: 8] <= s_axis_tdata;;
//                                if (byte_count == 39) begin
//                                    bit_pos <= 0;
//                                end
//                            end
                        end
                        "E": begin
                            if (byte_count >= 11 && byte_count <= 18) begin
                                order_ref[bit_pos -: 8] <= s_axis_tdata;;
                                if (byte_count == 18) begin
                                    bit_pos <= 31;
                                end
                                else begin
                                    bit_pos <= bit_pos - 8;
                                end
                            end
                            if (byte_count >= 19 && byte_count <= 22) begin
                                shares[bit_pos -: 8] <= s_axis_tdata;;
                                if (byte_count == 22) begin
                                    bit_pos <= 63;
                                end
                                else begin
                                    bit_pos <= bit_pos - 8;
                                end
                            end
                            if (byte_count >= 23 && byte_count <= 30) begin
                                match_num[bit_pos -: 8] <= s_axis_tdata;;
                                bit_pos <= bit_pos - 8;
                            end
                        end
                        "X": begin
                            if (byte_count >= 11 && byte_count <= 18) begin
                                order_ref[bit_pos -: 8] <= s_axis_tdata;;
                                if (byte_count == 18) begin
                                    bit_pos <= 31;
                                end
                                else begin
                                    bit_pos <= bit_pos - 8;
                                end
                            end
                            if (byte_count >= 19 && byte_count <= 22) begin
                                shares[bit_pos -: 8] <= s_axis_tdata;;
                                bit_pos <= bit_pos - 8;
                            end
                        end
                        "D": begin
                            if (byte_count >= 11 && byte_count <= 18) begin
                                order_ref[bit_pos -: 8] <= s_axis_tdata;;
                                bit_pos <= bit_pos - 8;
                            end
                        end
                    endcase
                    if (byte_count == (msg_length-1)) begin
                        bit_pos <= 63;
                        msg_state <= IDLE;
                        msg_valid <= 1;
                        if (s_axis_tvalid == 1) begin
                            byte_count <= 0;
                            msg_state <= IDLE;
                        end
                    end
                end
            endcase
        end
    end

endmodule

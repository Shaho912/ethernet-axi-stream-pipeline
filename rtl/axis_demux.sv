package demux_package;
    typedef enum logic [2:0] {
        IDLE = 3'b000,
        ETH_HEADER = 3'b001,
        IP_HEADER = 3'b010,
        UDP_HEADER = 3'b011,
        DECIDED = 3'b100
    } state_t;
endpackage
module axis_demux import demux_package::*;#(
    parameter DATA_WIDTH        = 8,
    parameter FIFO_DEPTH        = 64,          // must cover worst-case classification latency
    parameter [15:0] TARGET_PORT = 16'd1234
)(
    input  logic clk,
    input  logic rst,
    // slave side: raw frame in (from axis_sync_fifo, DMA path)
    input  logic [DATA_WIDTH-1:0] s_axis_tdata,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,
    input  logic                  s_axis_tlast,
    // master side 0: matched frames (dst port == TARGET_PORT)
    output logic [DATA_WIDTH-1:0] m_axis_matched_tdata,
    output logic                  m_axis_matched_tvalid,
    input  logic                  m_axis_matched_tready,
    output logic                  m_axis_matched_tlast,
    // master side 1: unmatched frames (everything else)
    output logic [DATA_WIDTH-1:0] m_axis_unmatched_tdata,
    output logic                  m_axis_unmatched_tvalid,
    input  logic                  m_axis_unmatched_tready,
    output logic                  m_axis_unmatched_tlast
);
    state_t state = IDLE;
    (* mark_debug = "true" *) logic [6:0] byte_count = '0;
    (* mark_debug = "true" *) logic [15:0] ethertype;
    (* mark_debug = "true" *) logic [7:0]  ip_protocol;
    (* mark_debug = "true" *) logic [3:0]  ip_ihl;
    (* mark_debug = "true" *) logic [15:0] dst_port;
    (* mark_debug = "true" *) logic verdict_valid = '0;
    (* mark_debug = "true" *) logic verdict_match = '0;

    logic                     fifo_s_axis_tready;
    logic [DATA_WIDTH-1:0]    fifo_m_tdata;
    logic                     fifo_m_tvalid;
    logic                     fifo_m_tlast;
    logic                     fifo_m_tready;

    logic output_tlast_xfer;
    assign output_tlast_xfer =
        (m_axis_matched_tvalid   && m_axis_matched_tready   && m_axis_matched_tlast) ||
        (m_axis_unmatched_tvalid && m_axis_unmatched_tready && m_axis_unmatched_tlast);

    assign s_axis_tready = fifo_s_axis_tready && !(state == IDLE && verdict_valid);

    logic dem_axis_tvalid;
    assign dem_axis_tvalid = s_axis_tvalid && !(state == IDLE && verdict_valid);

    assign m_axis_matched_tdata    = fifo_m_tdata;
    assign m_axis_unmatched_tdata  = fifo_m_tdata;

    assign m_axis_matched_tvalid   = verdict_valid &&  verdict_match && fifo_m_tvalid;
    assign m_axis_unmatched_tvalid = verdict_valid && !verdict_match && fifo_m_tvalid;

    assign m_axis_matched_tlast    = verdict_valid &&  verdict_match && fifo_m_tlast;
    assign m_axis_unmatched_tlast  = verdict_valid && !verdict_match && fifo_m_tlast;

    assign fifo_m_tready = verdict_valid && (verdict_match ? m_axis_matched_tready : m_axis_unmatched_tready);

    axis_sync_fifo #(
    .DATA_WIDTH(DATA_WIDTH),
    .DEPTH(FIFO_DEPTH)
    ) u_fifo (
        .clk(clk),
        .rst(rst),

        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tlast  (s_axis_tlast),
        .s_axis_tvalid (dem_axis_tvalid),
        .s_axis_tready (fifo_s_axis_tready),

        .m_axis_tdata  (fifo_m_tdata),
        .m_axis_tlast  (fifo_m_tlast),
        .m_axis_tvalid (fifo_m_tvalid),
        .m_axis_tready (fifo_m_tready)
    );
    always_ff@(posedge clk) begin
        if (rst) begin
            state      <= IDLE;
            byte_count <= '0;
            ethertype  <= '0;
            ip_protocol <= '0;
            ip_ihl     <= '0;
            dst_port   <= '0;
            verdict_valid <= '0;
            verdict_match <= '0;
        end
        else begin
            if (output_tlast_xfer) begin
                verdict_valid <= '0;
            end
            if (s_axis_tready && s_axis_tvalid) begin
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
                                        state <= DECIDED;
                                        verdict_match <= 0;
                                        verdict_valid <= 1;
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
                                        state <= DECIDED;
                                        verdict_match <= 0;
                                        verdict_valid <= 1;
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
                                        state <= DECIDED;
                                        verdict_match <= 0;
                                        verdict_valid <= 1;
                                end
                            end
                            if (byte_count == (21 + (ip_ihl << 2))) begin
                                state <= DECIDED;
                                verdict_match <= 1;
                                verdict_valid <= 1;
                            end
                        end
                        DECIDED: begin
                            byte_count <= byte_count + 1;
                        end
                    endcase
                end
            end
        end
    end
endmodule

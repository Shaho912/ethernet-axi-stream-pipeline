`timescale 1ns/1ps

module itch_parser_tb;

    localparam real CLK_PERIOD = 10.0;

    logic clk = 0;
    logic rst;

    logic [7:0] s_axis_tdata;
    logic       s_axis_tvalid;
    logic       s_axis_tready;
    logic       s_axis_tlast;

    logic        msg_valid;
    logic [7:0]  msg_type;
    logic [15:0] stock_locate;
    logic [63:0] order_ref;
    logic        buy_sell;
    logic [31:0] shares;
    logic [31:0] price;
    logic [63:0] match_num;

    int checks = 0;
    int errors = 0;

    itch_parser dut (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        .msg_valid(msg_valid),
        .msg_type(msg_type),
        .stock_locate(stock_locate),
        .order_ref(order_ref),
        .buy_sell(buy_sell),
        .shares(shares),
        .price(price),
        .match_num(match_num)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ---------------- checking ----------------

    task automatic check(input bit cond, input string msg);
        checks++;
        if (!cond) begin
            errors++;
            $display("[%0t] FAIL: %s", $time, msg);
        end else begin
            $display("[%0t] PASS: %s", $time, msg);
        end
    endtask

    // ---------------- passive capture (always running) ----------------
    // Every time msg_valid pulses, snapshot the parsed fields into
    // parallel queues -- lets the back-to-back test verify two messages
    // arrived in the right order with the right data, without needing to
    // pause the sender in between (matches how DUT self-resyncs).

    byte        cap_msg_type[$];
    bit [15:0]  cap_stock_locate[$];
    bit [63:0]  cap_order_ref[$];
    bit         cap_buy_sell[$];
    bit [31:0]  cap_shares[$];
    bit [31:0]  cap_price[$];
    bit [63:0]  cap_match_num[$];

    always @(posedge clk) begin
        if (!rst && msg_valid) begin
            cap_msg_type.push_back(msg_type);
            cap_stock_locate.push_back(stock_locate);
            cap_order_ref.push_back(order_ref);
            cap_buy_sell.push_back(buy_sell);
            cap_shares.push_back(shares);
            cap_price.push_back(price);
            cap_match_num.push_back(match_num);
        end
    end

    task automatic clear_capture();
        cap_msg_type.delete();
        cap_stock_locate.delete();
        cap_order_ref.delete();
        cap_buy_sell.delete();
        cap_shares.delete();
        cap_price.delete();
        cap_match_num.delete();
    endtask

    // ---------------- message construction ----------------
    //
    // Icarus Verilog (v12) crashes on `ref` queue ports, on ANY queue passed
    // as a function/task argument (even `input`-only), and on an automatic
    // task declaring a local queue and copying a global queue into it. So --
    // same workaround as axis_demux_tb.sv -- everything here operates on one
    // module-scope global byte queue (g_msg) with zero queue arguments.

    byte g_msg[$];

    task automatic push8(input byte v);
        g_msg.push_back(v);
    endtask

    task automatic push16(input bit [15:0] v);
        push8(v[15:8]);
        push8(v[7:0]);
    endtask

    task automatic push32(input bit [31:0] v);
        push16(v[31:16]);
        push16(v[15:0]);
    endtask

    task automatic push64(input bit [63:0] v);
        push32(v[63:32]);
        push32(v[31:0]);
    endtask

    // Builds one ITCH message into g_msg. clear_first=0 appends onto
    // whatever's already in g_msg instead of starting fresh -- used to
    // build two back-to-back messages into a single continuous byte stream
    // with zero gap, matching how the real DUT self-resyncs mid-stream.
    task automatic build_msg(
        input byte        mtype,
        input bit [15:0]  loc,
        input bit [63:0]  oref,
        input bit         bs,       // 1=Buy, 0=Sell (A/F only)
        input bit [31:0]  sh,
        input bit [31:0]  px,       // A/F only
        input bit [63:0]  mn,       // E only
        input bit         clear_first = 1'b1
    );
        if (clear_first) g_msg.delete();

        // common header: type(1) + stock_locate(2) + tracking_number(2,
        // dummy) + timestamp(6, dummy)
        push8(mtype);
        push16(loc);
        push16(16'h0000);
        push32(32'h0000_0000);
        push16(16'h0000);

        case (mtype)
            "A": begin
                push64(oref);
                push8(bs ? "B" : "S");
                push32(sh);
                for (int i = 0; i < 8; i++) push8("T");  // dummy stock ticker
                push32(px);
            end
            "F": begin
                push64(oref);
                push8(bs ? "B" : "S");
                push32(sh);
                for (int i = 0; i < 8; i++) push8("T");
                push32(px);
                push32(32'hAAAA_BBBB);  // dummy MPID, unparsed by DUT
            end
            "E": begin
                push64(oref);
                push32(sh);   // executed shares
                push64(mn);   // match number
            end
            "X": begin
                push64(oref);
                push32(sh);   // canceled shares
            end
            "D": begin
                push64(oref);
            end
        endcase
    endtask

    // Drives g_msg out over s_axis_*, one byte per accepted beat.
    task automatic send_msg();
        int n;
        n = g_msg.size();
        for (int i = 0; i < n; i++) begin
            s_axis_tdata  <= g_msg[i];
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= (i == n-1);
            @(posedge clk);
            while (!s_axis_tready) @(posedge clk);
        end
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
    endtask

    task automatic wait_for_capture_count(input int target, input int timeout_cycles = 500);
        int n;
        n = 0;
        while (cap_msg_type.size() < target && n < timeout_cycles) begin
            @(posedge clk);
            n++;
        end
        check(n < timeout_cycles, "message(s) parsed within timeout");
    endtask

    // ---------------- test sequences ----------------

    initial begin
        rst = 1'b1;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        s_axis_tdata  = 8'h00;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // ---- Test 1: Add Order, no MPID ('A') ----
        clear_capture();
        build_msg("A", 16'h0007, 64'h0000_0000_0000_2A2A, 1'b1, 32'd500, 32'd101_2500, 64'h0);
        send_msg();
        wait_for_capture_count(1);
        check(cap_msg_type[0]      == "A",                       "Test1(A): msg_type");
        check(cap_stock_locate[0]  == 16'h0007,                  "Test1(A): stock_locate");
        check(cap_order_ref[0]     == 64'h0000_0000_0000_2A2A,   "Test1(A): order_ref");
        check(cap_buy_sell[0]      == 1'b1,                      "Test1(A): buy_sell (Buy)");
        check(cap_shares[0]        == 32'd500,                   "Test1(A): shares");
        check(cap_price[0]         == 32'd101_2500,               "Test1(A): price");

        // ---- Test 2: Add Order with MPID ('F') -- MPID bytes present on
        //      the wire but not parsed; everything else must still line up
        //      (regression for the byte-alignment bugs from earlier drafts)
        clear_capture();
        build_msg("F", 16'h0009, 64'hDEAD_BEEF_0000_0001, 1'b0, 32'd250, 32'd55_0000, 64'h0);
        send_msg();
        wait_for_capture_count(1);
        check(cap_msg_type[0]      == "F",                       "Test2(F): msg_type");
        check(cap_stock_locate[0]  == 16'h0009,                  "Test2(F): stock_locate");
        check(cap_order_ref[0]     == 64'hDEAD_BEEF_0000_0001,   "Test2(F): order_ref");
        check(cap_buy_sell[0]      == 1'b0,                      "Test2(F): buy_sell (Sell)");
        check(cap_shares[0]        == 32'd250,                   "Test2(F): shares");
        check(cap_price[0]         == 32'd55_0000,                "Test2(F): price");

        // ---- Test 3: Order Executed ('E') -- exercises the 8-byte
        //      match_num field and the bit_pos handoff after a 4-byte field
        clear_capture();
        build_msg("E", 16'h0007, 64'h0000_0000_0000_2A2A, 1'b0, 32'd200, 32'h0,
                  64'h1122_3344_5566_7788);
        send_msg();
        wait_for_capture_count(1);
        check(cap_msg_type[0]      == "E",                       "Test3(E): msg_type");
        check(cap_order_ref[0]     == 64'h0000_0000_0000_2A2A,   "Test3(E): order_ref");
        check(cap_shares[0]        == 32'd200,                   "Test3(E): executed shares");
        check(cap_match_num[0]     == 64'h1122_3344_5566_7788,   "Test3(E): match_num (full 8 bytes)");

        // ---- Test 4: Order Cancel ('X') -- regression for the earlier bug
        //      where X never reached the done/valid transition at all
        clear_capture();
        build_msg("X", 16'h0007, 64'h0000_0000_0000_2A2A, 1'b0, 32'd100, 32'h0, 64'h0);
        send_msg();
        wait_for_capture_count(1);
        check(cap_msg_type[0]      == "X",                       "Test4(X): msg_type");
        check(cap_order_ref[0]     == 64'h0000_0000_0000_2A2A,   "Test4(X): order_ref");
        check(cap_shares[0]        == 32'd100,                   "Test4(X): canceled shares");

        // ---- Test 5: Order Delete ('D') -- shortest message, order_ref only
        clear_capture();
        build_msg("D", 16'h0007, 64'h0000_0000_0000_2A2A, 1'b0, 32'h0, 32'h0, 64'h0);
        send_msg();
        wait_for_capture_count(1);
        check(cap_msg_type[0]      == "D",                       "Test5(D): msg_type");
        check(cap_order_ref[0]     == 64'h0000_0000_0000_2A2A,   "Test5(D): order_ref");

        // ---- Test 6: back-to-back messages, zero gap -- regression for
        //      the resync bug (lost byte / stale msg_length / byte_count
        //      never resetting) that showed up once DONE was folded away.
        //      Build two DIFFERENT message types into ONE continuous byte
        //      stream and confirm both land correctly, in order.
        clear_capture();
        build_msg("A", 16'h0011, 64'h0000_0000_0000_0BBB, 1'b1, 32'd10, 32'd9_9999, 64'h0,
                  1'b1);                                     // clear_first=1: starts g_msg
        build_msg("D", 16'h0011, 64'h0000_0000_0000_0BBB, 1'b0, 32'h0, 32'h0, 64'h0,
                  1'b0);                                     // clear_first=0: appends right after
        send_msg();
        wait_for_capture_count(2);
        check(cap_msg_type[0]     == "A" && cap_msg_type[1] == "D",
              "Test6: two back-to-back messages both parsed, in order");
        check(cap_order_ref[0]    == 64'h0000_0000_0000_0BBB &&
              cap_order_ref[1]    == 64'h0000_0000_0000_0BBB,
              "Test6: order_ref correct on both messages (no cross-message corruption)");
        check(cap_shares[0]       == 32'd10,
              "Test6: first message's shares field not corrupted by the second message");
        check(cap_buy_sell[0]     == 1'b1,
              "Test6: first message's buy_sell not corrupted by the second message");

        // ---- Test 7: msg_valid is a clean 1-cycle pulse, not sticky ----
        clear_capture();
        build_msg("D", 16'h0001, 64'h0000_0000_0000_0001, 1'b0, 32'h0, 32'h0, 64'h0);
        send_msg();
        wait_for_capture_count(1);
        @(posedge clk);
        check(msg_valid == 1'b0,
              "Test7: msg_valid deasserts the cycle after the pulse (not stuck high)");

        $display("\n==================================================");
        $display("TOTAL CHECKS: %0d   ERRORS: %0d", checks, errors);
        $display("==================================================\n");

        $finish;
    end

endmodule

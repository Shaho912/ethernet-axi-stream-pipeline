`timescale 1ns/1ps

module axis_demux_tb;

    localparam int DATA_WIDTH   = 8;
    localparam int FIFO_DEPTH   = 64;
    localparam bit [15:0] TARGET_PORT = 16'd1234;
    localparam real CLK_PERIOD  = 10.0;

    logic clk = 0;
    logic rst;

    // slave (input) side
    logic [7:0] s_axis_tdata;
    logic       s_axis_tvalid;
    logic       s_axis_tready;
    logic       s_axis_tlast;

    // matched output
    logic [7:0] m_matched_tdata;
    logic       m_matched_tvalid;
    logic       m_matched_tready;
    logic       m_matched_tlast;

    // unmatched output
    logic [7:0] m_unmatched_tdata;
    logic       m_unmatched_tvalid;
    logic       m_unmatched_tready;
    logic       m_unmatched_tlast;

    int checks = 0;
    int errors = 0;

    axis_demux #(
        .DATA_WIDTH (DATA_WIDTH),
        .FIFO_DEPTH (FIFO_DEPTH),
        .TARGET_PORT(TARGET_PORT)
    ) dut (
        .clk(clk), .rst(rst),
        .s_axis_tdata (s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast (s_axis_tlast),

        .m_axis_matched_tdata (m_matched_tdata),
        .m_axis_matched_tvalid(m_matched_tvalid),
        .m_axis_matched_tready(m_matched_tready),
        .m_axis_matched_tlast (m_matched_tlast),

        .m_axis_unmatched_tdata (m_unmatched_tdata),
        .m_axis_unmatched_tvalid(m_unmatched_tvalid),
        .m_axis_unmatched_tready(m_unmatched_tready),
        .m_axis_unmatched_tlast (m_unmatched_tlast)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ---------------- passive capture (always running) ----------------

    byte matched_capture[$];
    byte unmatched_capture[$];
    bit  matched_tlast_seen;
    bit  unmatched_tlast_seen;

    always @(posedge clk) begin
        if (!rst) begin
            if (m_matched_tvalid && m_matched_tready) begin
                matched_capture.push_back(m_matched_tdata);
                if (m_matched_tlast) matched_tlast_seen <= 1'b1;
            end
            if (m_unmatched_tvalid && m_unmatched_tready) begin
                unmatched_capture.push_back(m_unmatched_tdata);
                if (m_unmatched_tlast) unmatched_tlast_seen <= 1'b1;
            end
        end
    end

    task automatic clear_capture();
        matched_capture.delete();
        unmatched_capture.delete();
        matched_tlast_seen = 1'b0;
        unmatched_tlast_seen = 1'b0;
    endtask

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

    // Icarus Verilog (v12) crashes ("draw_eval_function_argument: Assertion
    // `0' failed") when a dynamic queue is passed as a function/task input
    // argument, even by value. So instead of a queues_equal(a, b) function,
    // each call site assigns the two queues to compare into these globals
    // directly (a plain queue-to-queue copy, not argument passing), then
    // calls the argument-less queues_equal_g() below.
    byte g_cmp_a[$];
    byte g_cmp_b[$];

    function automatic bit queues_equal_g();
        if (g_cmp_a.size() != g_cmp_b.size()) return 1'b0;
        for (int i = 0; i < g_cmp_a.size(); i++) begin
            if (g_cmp_a[i] !== g_cmp_b[i]) return 1'b0;
        end
        return 1'b1;
    endfunction

    // At each call site: assign g_cmp_a/g_cmp_b directly (plain queue-to-
    // queue copies, not function/task argument passing -- passing a queue
    // as an argument is what crashes Icarus), then call queues_equal_g().

    // ---------------- frame construction ----------------
    //
    // NOTE: Icarus Verilog (v12, used to simulate this testbench) does not
    // support `ref` task/function ports, and `output` ports do NOT copy the
    // actual's existing contents in at task start (they only copy the
    // formal's final value out at the end) -- so an `output byte q[$]`
    // helper called repeatedly would silently erase whatever the caller had
    // already built. To sidestep that entirely, these helpers operate on
    // shared testbench-global queues (g_payload, g_frame) instead of taking
    // queue arguments at all.

    byte g_payload[$];
    byte g_frame[$];

    task automatic push16(input bit [15:0] v);
        g_frame.push_back(v[15:8]);
        g_frame.push_back(v[7:0]);
    endtask

    // Builds a full raw Ethernet frame (headers included) into g_frame,
    // using whatever's currently in g_payload as the UDP payload.
    // ihl is in 32-bit words (5 = standard 20-byte header, no options).
    task automatic build_frame(
        input bit [15:0] ethertype,
        input bit [7:0]  ip_proto,
        input bit [3:0]  ihl,
        input bit [15:0] dst_port,
        input bit [15:0] src_port
    );
        int ihl_bytes;
        int udp_len;
        int ip_total_len;
        int opt_bytes;

        g_frame.delete();

        ihl_bytes    = ihl * 4;
        udp_len      = 8 + g_payload.size();
        ip_total_len = ihl_bytes + udp_len;
        opt_bytes    = ihl_bytes - 20;

        // -- Ethernet header --
        for (int i = 0; i < 6; i++) g_frame.push_back(8'hAA); // dst MAC (dummy)
        for (int i = 0; i < 6; i++) g_frame.push_back(8'hBB); // src MAC (dummy)
        push16(ethertype);

        // -- IP header --
        g_frame.push_back({4'h4, ihl});          // version=4, IHL
        g_frame.push_back(8'h00);                // ToS
        push16(ip_total_len[15:0]);              // total length
        push16(16'h0000);                        // identification
        push16(16'h0000);                        // flags/frag offset
        g_frame.push_back(8'h80);                // TTL
        g_frame.push_back(ip_proto);             // protocol
        push16(16'h0000);                        // header checksum (not checked by DUT)
        g_frame.push_back(8'hC0); g_frame.push_back(8'hA8); g_frame.push_back(8'h01); g_frame.push_back(8'h14); // src 192.168.1.20
        g_frame.push_back(8'hC0); g_frame.push_back(8'hA8); g_frame.push_back(8'h01); g_frame.push_back(8'h0A); // dst 192.168.1.10
        for (int i = 0; i < opt_bytes; i++) g_frame.push_back(8'h00); // IP options padding

        // -- UDP header --
        push16(src_port);
        push16(dst_port);
        push16(udp_len[15:0]);
        push16(16'h0000); // checksum (not checked by DUT)

        // -- payload --
        foreach (g_payload[i]) g_frame.push_back(g_payload[i]);
    endtask

    task automatic make_payload(input int len, input byte seed = 8'h00);
        g_payload.delete();
        for (int i = 0; i < len; i++) g_payload.push_back(seed + i[7:0]);
    endtask

    // ---------------- driving the slave interface ----------------

    // Drives g_frame out over s_axis_*, one byte per accepted beat. stall_prob
    // (0-100) randomly deasserts tvalid between beats to exercise gaps in the
    // input stream. Reads g_frame directly rather than snapshotting it into a
    // local queue variable -- Icarus Verilog (v12) crashes
    // ("vthread_get_rd_context_item: Assertion failed") when an automatic
    // task declares a local queue and assigns a global queue into it. This
    // is safe here because nothing rebuilds g_frame while a send is in
    // flight (the testbench is single-threaded/sequential).
    task automatic send_frame(input int stall_prob = 0);
        int n;
        n = g_frame.size();
        for (int i = 0; i < n; i++) begin
            if (stall_prob > 0) begin
                while ($urandom_range(0, 99) < stall_prob) begin
                    s_axis_tvalid <= 1'b0;
                    @(posedge clk);
                end
            end
            s_axis_tdata  <= g_frame[i];
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= (i == n-1);
            @(posedge clk);
            while (!s_axis_tready) @(posedge clk);
        end
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
    endtask

    // Waits for either output stream to signal tlast (i.e. the frame has fully
    // drained through axis_demux), with a generous timeout.
    task automatic wait_for_drain(input int timeout_cycles = 500);
        int n;
        n = 0;
        while (!matched_tlast_seen && !unmatched_tlast_seen && n < timeout_cycles) begin
            @(posedge clk);
            n++;
        end
        check(n < timeout_cycles, "frame drained within timeout (no deadlock/stuck verdict)");
    endtask

    // ---------------- test sequences ----------------

    initial begin
        rst = 1'b1;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        s_axis_tdata  = 8'h00;
        m_matched_tready   = 1'b1;
        m_unmatched_tready = 1'b1;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // ---- Test 1: matched frame (dst port == TARGET_PORT) ----
        clear_capture();
        make_payload(11, "h");
        build_frame(16'h0800, 8'h11, 4'd5, TARGET_PORT, 16'd5000);
        send_frame();
        wait_for_drain();
        check(matched_tlast_seen && !unmatched_tlast_seen,
              "Test1: matched frame routed to matched port only");
        g_cmp_a = matched_capture; g_cmp_b = g_frame;
        check(queues_equal_g(),
              "Test1: matched output byte-for-byte equals input frame (full frame, headers included)");
        check(unmatched_capture.size() == 0,
              "Test1: unmatched port stayed completely silent");

        // ---- Test 2: unmatched frame (wrong dst port) ----
        clear_capture();
        make_payload(11, "x");
        build_frame(16'h0800, 8'h11, 4'd5, 16'd9999, 16'd5000);
        send_frame();
        wait_for_drain();
        check(unmatched_tlast_seen && !matched_tlast_seen,
              "Test2: wrong-dst-port frame routed to unmatched port only");
        g_cmp_a = unmatched_capture; g_cmp_b = g_frame;
        check(queues_equal_g(),
              "Test2: unmatched output byte-for-byte equals input frame");
        check(matched_capture.size() == 0,
              "Test2: matched port stayed completely silent");

        // ---- Test 3: EtherType mismatch (e.g. ARP, not IPv4) ----
        clear_capture();
        make_payload(20, "a");
        build_frame(16'h0806, 8'h11, 4'd5, TARGET_PORT, 16'd5000);
        send_frame();
        wait_for_drain();
        check(unmatched_tlast_seen && !matched_tlast_seen,
              "Test3: non-IPv4 EtherType routed to unmatched port");
        g_cmp_a = unmatched_capture; g_cmp_b = g_frame;
        check(queues_equal_g(),
              "Test3: unmatched output matches full input frame");

        // ---- Test 4: IP protocol mismatch (e.g. TCP, not UDP) ----
        clear_capture();
        make_payload(20, "b");
        build_frame(16'h0800, 8'h06, 4'd5, TARGET_PORT, 16'd5000);
        send_frame();
        wait_for_drain();
        check(unmatched_tlast_seen && !matched_tlast_seen,
              "Test4: non-UDP protocol routed to unmatched port");
        g_cmp_a = unmatched_capture; g_cmp_b = g_frame;
        check(queues_equal_g(),
              "Test4: unmatched output matches full input frame");

        // ---- Test 5: large payload -- stresses post-tlast drain (regression
        //      test for the classification-window backlog / premature
        //      verdict-clear bug) ----
        clear_capture();
        make_payload(200, "p");
        build_frame(16'h0800, 8'h11, 4'd5, TARGET_PORT, 16'd5000);
        send_frame();
        wait_for_drain();
        check(matched_tlast_seen && !unmatched_tlast_seen,
              "Test5: large matched frame routed correctly");
        g_cmp_a = matched_capture; g_cmp_b = g_frame;
        check(queues_equal_g(),
              "Test5: large frame drains completely and correctly after tlast (no dropped tail bytes)");

        // ---- Test 6: back-to-back frames -- s_axis_tready must hold off a new
        //      frame until the previous frame's verdict has fully drained ----
        clear_capture();
        make_payload(11, "c");
        build_frame(16'h0800, 8'h11, 4'd5, TARGET_PORT, 16'd5000);
        // Hold matched_tready low so this frame's drain stalls, giving us a
        // window to observe s_axis_tready being deasserted for a new frame.
        m_matched_tready = 1'b0;
        send_frame();
        // At this point frame A's input side is done but its verdict is
        // still latched (undrained) -- attempting to start frame B's first
        // byte right now should be refused.
        s_axis_tdata  <= 8'hFF;
        s_axis_tvalid <= 1'b1;
        s_axis_tlast  <= 1'b0;
        @(posedge clk);
        check(s_axis_tready == 1'b0,
              "Test6: s_axis_tready deasserted while previous frame's verdict is still undrained");
        s_axis_tvalid <= 1'b0;
        m_matched_tready = 1'b1; // release the drain
        wait_for_drain();
        check(matched_tlast_seen,
              "Test6: frame A eventually drains once downstream releases tready");

        // now send frame B for real and confirm it processes cleanly after A cleared
        clear_capture();
        make_payload(11, "d");
        build_frame(16'h0800, 8'h11, 4'd5, 16'd8888, 16'd5000);
        send_frame();
        wait_for_drain();
        check(unmatched_tlast_seen && !matched_tlast_seen,
              "Test6: frame B (after A cleared) routes correctly with no leftover state from A");
        g_cmp_a = unmatched_capture; g_cmp_b = g_frame;
        check(queues_equal_g(),
              "Test6: frame B data is clean, not corrupted by frame A's backlog");

        $display("\n==================================================");
        $display("TOTAL CHECKS: %0d   ERRORS: %0d", checks, errors);
        $display("==================================================\n");

        $finish;
    end

endmodule

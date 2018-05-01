// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import CfMath::log2;

module axi4_w_buffer
  #(
    parameter AXI_DATA_WIDTH   = 32,
    parameter AXI_ID_WIDTH     = 4,
    parameter AXI_USER_WIDTH   = 4,
    parameter ENABLE_L2TLB     = 0,
    parameter HUM_BUFFER_DEPTH = 16
  )
  (
    input  logic                        axi4_aclk,
    input  logic                        axi4_arstn,

    // L1 & L2 interfaces
    output logic                        l1_done_o,
    input  logic                        l1_accept_i,
    input  logic                        l1_save_i,
    input  logic                        l1_drop_i,
    input  logic                        l1_master_i,
    input  logic     [AXI_ID_WIDTH-1:0] l1_id_i,
    input  logic                        l1_prefetch_i,
    input  logic                        l1_hit_i,

    output logic                        l2_done_o,
    input  logic                        l2_accept_i,
    input  logic                        l2_drop_i,
    input  logic                        l2_master_i,
    input  logic     [AXI_ID_WIDTH-1:0] l2_id_i,
    input  logic                        l2_prefetch_i,
    input  logic                        l2_hit_i,

    output logic                        master_select_o,
    output logic                        input_stall_o,
    output logic                        output_stall_o,

    // B sender interface
    output logic                        b_drop_o,
    input  logic                        b_done_i,
    output logic     [AXI_ID_WIDTH-1:0] id_o,
    output logic                        prefetch_o,
    output logic                        hit_o,

    // AXI W channel interfaces
    input  logic   [AXI_DATA_WIDTH-1:0] s_axi4_wdata,
    input  logic                        s_axi4_wvalid,
    output logic                        s_axi4_wready,
    input  logic [AXI_DATA_WIDTH/8-1:0] s_axi4_wstrb,
    input  logic                        s_axi4_wlast,
    input  logic   [AXI_USER_WIDTH-1:0] s_axi4_wuser,

    output logic   [AXI_DATA_WIDTH-1:0] m_axi4_wdata,
    output logic                        m_axi4_wvalid,
    input  logic                        m_axi4_wready,
    output logic [AXI_DATA_WIDTH/8-1:0] m_axi4_wstrb,
    output logic                        m_axi4_wlast,
    output logic   [AXI_USER_WIDTH-1:0] m_axi4_wuser
  );

  localparam BUFFER_WIDTH  = AXI_DATA_WIDTH+AXI_USER_WIDTH+AXI_DATA_WIDTH/8+1;
  localparam L1_FIFO_WIDTH = 2+AXI_ID_WIDTH+4;
  localparam L2_FIFO_WIDTH = 2+AXI_ID_WIDTH+3;

  localparam INPUT_BUFFER_DEPTH = 4;
  localparam L1_FIFO_DEPTH      = 8;
  localparam L2_FIFO_DEPTH      = 4;

  logic      [AXI_DATA_WIDTH-1:0] axi4_wdata;
  logic                           axi4_wvalid;
  logic                           axi4_wready;
  logic    [AXI_DATA_WIDTH/8-1:0] axi4_wstrb;
  logic                           axi4_wlast;
  logic      [AXI_USER_WIDTH-1:0] axi4_wuser;

  logic        [BUFFER_WIDTH-1:0] data_in;
  logic        [BUFFER_WIDTH-1:0] data_out;

  logic       [L1_FIFO_WIDTH-1:0] l1_fifo_in;
  logic       [L1_FIFO_WIDTH-1:0] l1_fifo_out;
  logic                           l1_fifo_valid_out;
  logic                           l1_fifo_ready_in;
  logic                           l1_fifo_valid_in;
  logic                           l1_fifo_ready_out;

  logic                           l1_req;
  logic                           l1_accept_cur, l1_save_cur, l1_drop_cur;
  logic                           l1_master_cur;
  logic        [AXI_ID_WIDTH-1:0] l1_id_cur;
  logic                           l1_hit_cur, l1_prefetch_cur;
  logic [log2(L1_FIFO_DEPTH)-1:0] n_l1_save_SP;

  logic       [L2_FIFO_WIDTH-1:0] l2_fifo_in;
  logic       [L2_FIFO_WIDTH-1:0] l2_fifo_out;
  logic                           l2_fifo_valid_out;
  logic                           l2_fifo_ready_in;
  logic                           l2_fifo_valid_in;
  logic                           l2_fifo_ready_out;

  logic                           l2_req;
  logic                           l2_accept_cur, l2_drop_cur;
  logic                           l2_master_cur;
  logic        [AXI_ID_WIDTH-1:0] l2_id_cur;
  logic                           l2_hit_cur, l2_prefetch_cur;

  logic                           fifo_select, fifo_select_SN, fifo_select_SP;
  logic                           w_done;
  logic                           b_drop_set;

  // HUM buffer signals
  logic                           hum_buf_ready_out;
  logic                           hum_buf_valid_in;
  logic                           hum_buf_ready_in;
  logic                           hum_buf_valid_out;

  logic      [AXI_DATA_WIDTH-1:0] hum_buf_wdata;
  logic    [AXI_DATA_WIDTH/8-1:0] hum_buf_wstrb;
  logic                           hum_buf_wlast;
  logic      [AXI_USER_WIDTH-1:0] hum_buf_wuser;

  logic        [BUFFER_WIDTH-1:0] hum_buf_in;
  logic        [BUFFER_WIDTH-1:0] hum_buf_out;

  logic                           hum_buf_flush;
  logic                           hum_buf_almost_full;

  logic                           stop_store;
  logic                           wlast_in, wlast_out;
  logic                     [1:0] n_wlast_SP;
  logic                           block_forwarding;

  // Search FSM
  typedef enum logic        [3:0] {STORE,                       BYPASS,
                                   WAIT_L1_BYPASS_YES,          WAIT_L2_BYPASS_YES,
                                   WAIT_L1_BYPASS_NO,           WAIT_L2_BYPASS_NO,
                                   FLUSH,                       DISCARD,
                                   DISCARD_FINISH,              FLUSH_AND_DISCARD,
                                   FLUSH_AND_DISCARD_FINISH} hum_buf_state_t;
  hum_buf_state_t                 hum_buf_SP; // Present state
  hum_buf_state_t                 hum_buf_SN; // Next State

  assign data_in                                                                               [0] = s_axi4_wlast;
  assign data_in                                                                [AXI_DATA_WIDTH:1] = s_axi4_wdata;
  assign data_in                                [AXI_DATA_WIDTH+AXI_DATA_WIDTH/8:AXI_DATA_WIDTH+1] = s_axi4_wstrb;
  assign data_in[AXI_DATA_WIDTH+AXI_USER_WIDTH+AXI_DATA_WIDTH/8:AXI_DATA_WIDTH+AXI_DATA_WIDTH/8+1] = s_axi4_wuser;

  assign axi4_wlast  = data_out[0];
  assign axi4_wdata  = data_out[AXI_DATA_WIDTH:1];
  assign axi4_wstrb  = data_out[AXI_DATA_WIDTH+AXI_DATA_WIDTH/8:AXI_DATA_WIDTH+1];
  assign axi4_wuser  = data_out[AXI_DATA_WIDTH+AXI_USER_WIDTH+AXI_DATA_WIDTH/8:AXI_DATA_WIDTH+AXI_DATA_WIDTH/8+1];

  axi_buffer_rab
    #(
      .DATA_WIDTH       ( BUFFER_WIDTH        ),
      .BUFFER_DEPTH     ( INPUT_BUFFER_DEPTH  )
      )
    u_input_buf
    (
      .clk       ( axi4_aclk     ),
      .rstn      ( axi4_arstn    ),
      // Pop
      .valid_out ( axi4_wvalid   ),
      .data_out  ( data_out      ),
      .ready_in  ( axi4_wready   ),
      // Push
      .valid_in  ( s_axi4_wvalid ),
      .data_in   ( data_in       ),
      .ready_out ( s_axi4_wready )
    );

  axi_buffer_rab
    #(
      .DATA_WIDTH       ( L1_FIFO_WIDTH ),
      .BUFFER_DEPTH     ( L1_FIFO_DEPTH )
      )
    u_l1_fifo
    (
      .clk       ( axi4_aclk         ),
      .rstn      ( axi4_arstn        ),
      // Pop
      .data_out  ( l1_fifo_out       ),
      .valid_out ( l1_fifo_valid_out ),
      .ready_in  ( l1_fifo_ready_in  ),
      // Push
      .valid_in  ( l1_fifo_valid_in  ),
      .data_in   ( l1_fifo_in        ),
      .ready_out ( l1_fifo_ready_out )
    );

    assign l1_fifo_in      = {l1_prefetch_i, l1_hit_i, l1_id_i, l1_master_i, l1_accept_i, l1_save_i, l1_drop_i};
    assign l1_prefetch_cur = l1_fifo_out[2+AXI_ID_WIDTH+3];
    assign l1_hit_cur      = l1_fifo_out[1+AXI_ID_WIDTH+3];
    assign l1_id_cur       = l1_fifo_out[AXI_ID_WIDTH+3:4];
    assign l1_master_cur   = l1_fifo_out[3];
    assign l1_accept_cur   = l1_fifo_out[2];
    assign l1_save_cur     = l1_fifo_out[1];
    assign l1_drop_cur     = l1_fifo_out[0];

    // Push upon receiving new reqeusts from the TLB.
    assign l1_req           = l1_accept_i | l1_save_i | l1_drop_i;
    assign l1_fifo_valid_in = l1_req & l1_fifo_ready_out;

    // Signal handshake
    assign l1_done_o  = l1_fifo_valid_in;
    assign l2_done_o  = l2_fifo_valid_in;

    // Stall AW input of L1 TLB
    assign input_stall_o = ~(l1_fifo_ready_out & l2_fifo_ready_out);

    // Interface b_drop signals + handshake
    always_comb begin
      if (fifo_select == 1'b0) begin
        prefetch_o       = l1_prefetch_cur;
        hit_o            = l1_hit_cur;
        id_o             = l1_id_cur;

        l1_fifo_ready_in = w_done | b_done_i;
        l2_fifo_ready_in = 1'b0;
      end else begin
        prefetch_o       = l2_prefetch_cur;
        hit_o            = l2_hit_cur;
        id_o             = l2_id_cur;

        l1_fifo_ready_in = 1'b0;
        l2_fifo_ready_in = w_done | b_done_i;
      end
    end

    // Detect when an L1 transaction save request enters or exits the L1 FIFO.
    assign l1_save_in  = l1_fifo_valid_in & l1_save_i;
    assign l1_save_out = l1_fifo_ready_in & l1_save_cur;

    // Count the number of L1 transaction to save in the L1 FIFO.
    always_ff @(posedge axi4_aclk or negedge axi4_arstn) begin
      if (axi4_arstn == 0) begin
        n_l1_save_SP <= '0;
      end else if (l1_save_in ^ l1_save_out) begin
        if (l1_save_in) begin
          n_l1_save_SP <= n_l1_save_SP + 1'b1;
        end else if (l1_save_out) begin
          n_l1_save_SP <= n_l1_save_SP - 1'b1;
        end
      end
    end

    // Stall forwarding of AW L1 hits if:
    // 1. The HUM buffer does not allow to be bypassed.
    // 2. There are multiple L1 save requests in the FIFO, i.e., multiple L2 outputs pending.
    assign output_stall_o = (n_l1_save_SP > 1) || (block_forwarding == 1'b1);

  generate
  if (ENABLE_L2TLB == 1) begin : HUM_BUFFER

    assign hum_buf_in                                                                               [0] = axi4_wlast;
    assign hum_buf_in                                                                [AXI_DATA_WIDTH:1] = axi4_wdata;
    assign hum_buf_in                                [AXI_DATA_WIDTH+AXI_DATA_WIDTH/8:AXI_DATA_WIDTH+1] = axi4_wstrb;
    assign hum_buf_in[AXI_DATA_WIDTH+AXI_USER_WIDTH+AXI_DATA_WIDTH/8:AXI_DATA_WIDTH+AXI_DATA_WIDTH/8+1] = axi4_wuser;

    assign hum_buf_wlast = hum_buf_out[0];
    assign hum_buf_wdata = hum_buf_out[AXI_DATA_WIDTH:1];
    assign hum_buf_wstrb = hum_buf_out[AXI_DATA_WIDTH+AXI_DATA_WIDTH/8:AXI_DATA_WIDTH+1];
    assign hum_buf_wuser = hum_buf_out[AXI_DATA_WIDTH+AXI_USER_WIDTH+AXI_DATA_WIDTH/8:AXI_DATA_WIDTH+AXI_DATA_WIDTH/8+1];

    axi_buffer_rab_bram
    #(
      .DATA_WIDTH       ( BUFFER_WIDTH      ),
      .BUFFER_DEPTH     ( HUM_BUFFER_DEPTH  )
      )
    u_hum_buf
    (
      .clk           ( axi4_aclk           ),
      .rstn          ( axi4_arstn          ),
      // Pop
      .data_out      ( hum_buf_out         ),
      .valid_out     ( hum_buf_valid_out   ),
      .ready_in      ( hum_buf_ready_in    ),
      // Push
      .valid_in      ( hum_buf_valid_in    ),
      .data_in       ( hum_buf_in          ),
      .ready_out     ( hum_buf_ready_out   ),
      // Clear
      .almost_full   ( hum_buf_almost_full ),
      .flush_entries ( hum_buf_flush       )
    );

    axi_buffer_rab
    #(
      .DATA_WIDTH       ( L2_FIFO_WIDTH ),
      .BUFFER_DEPTH     ( L2_FIFO_DEPTH )
      )
    u_l2_fifo
    (
      .clk       ( axi4_aclk         ),
      .rstn      ( axi4_arstn        ),
      // Pop
      .data_out  ( l2_fifo_out       ),
      .valid_out ( l2_fifo_valid_out ),
      .ready_in  ( l2_fifo_ready_in  ),
      // Push
      .valid_in  ( l2_fifo_valid_in  ),
      .data_in   ( l2_fifo_in        ),
      .ready_out ( l2_fifo_ready_out )
    );

    assign l2_fifo_in      = {l2_prefetch_i, l2_hit_i, l2_id_i, l2_master_i, l2_accept_i, l2_drop_i};
    assign l2_prefetch_cur = l2_fifo_out[2+AXI_ID_WIDTH+2];
    assign l2_hit_cur      = l2_fifo_out[1+AXI_ID_WIDTH+2];
    assign l2_id_cur       = l2_fifo_out[AXI_ID_WIDTH+2:3];
    assign l2_master_cur   = l2_fifo_out[2];
    assign l2_accept_cur   = l2_fifo_out[1];
    assign l2_drop_cur     = l2_fifo_out[0];

    // Push upon receiving new result from TLB.
    assign l2_req           = l2_accept_i | l2_drop_i;
    assign l2_fifo_valid_in = l2_req & l2_fifo_ready_out;

    assign wlast_in  =    axi4_wlast & hum_buf_valid_in  & hum_buf_ready_out;
    assign wlast_out = hum_buf_wlast & hum_buf_valid_out & hum_buf_ready_in;

    // Count the number of wlast beats in the HUM buffer.
    always_ff @(posedge axi4_aclk or negedge axi4_arstn) begin
      if (axi4_arstn == 0) begin
        n_wlast_SP <= '0;
      end else if (hum_buf_flush) begin
        n_wlast_SP <= '0;
      end else if (wlast_in ^ wlast_out) begin
        if (wlast_in) begin
          n_wlast_SP <= n_wlast_SP + 1'b1;
        end else if (wlast_out) begin
          n_wlast_SP <= n_wlast_SP - 1'b1;
        end
      end
    end

    always_ff @(posedge axi4_aclk or negedge axi4_arstn) begin
      if (axi4_arstn == 0) begin
        fifo_select_SP <= STORE;
      end else begin
        fifo_select_SP <= fifo_select_SN;
      end
    end

    always_ff @(posedge axi4_aclk or negedge axi4_arstn) begin
      if (axi4_arstn == 0) begin
        hum_buf_SP <= STORE;
      end else begin
        hum_buf_SP <= hum_buf_SN;
      end
    end

    always_comb begin : HUM_BUFFER_FSM
      hum_buf_SN       = hum_buf_SP;

      m_axi4_wlast     = 1'b0;
      m_axi4_wdata     =  'b0;
      m_axi4_wstrb     =  'b0;
      m_axi4_wuser     =  'b0;

      m_axi4_wvalid    = 1'b0;
      axi4_wready      = 1'b0;

      hum_buf_valid_in = 1'b0;
      hum_buf_ready_in = 1'b0;

      hum_buf_flush    = 1'b0;
      master_select_o  = 1'b0;

      w_done           = 1'b0; // read from FIFO without handshake with B sender
      b_drop_o         = 1'b0; // send data from FIFO to B sender (with handshake)
      fifo_select      = 1'b0;

      fifo_select_SN   = fifo_select_SP;
      stop_store       = 1'b0;

      block_forwarding = 1'b0;

      unique case (hum_buf_SP)

        STORE : begin
          // Simply store the data in the buffer.
          hum_buf_valid_in = axi4_wvalid & hum_buf_ready_out;
          axi4_wready      = hum_buf_ready_out;

          // We have got a full burst, thus stop storing.
          if (wlast_in) begin
            hum_buf_SN = WAIT_L1_BYPASS_YES;

          // The buffer is full, thus wait for decision.
          end else if (~hum_buf_ready_out) begin
            hum_buf_SN = WAIT_L1_BYPASS_NO;
          end

          // Avoid the forwarding of L1 hits untill we know whether we can bypass.
          if (l1_fifo_valid_out & l1_save_cur) begin
            block_forwarding = 1'b1;
          end
        end

        WAIT_L1_BYPASS_YES : begin
          // Wait for orders from L1 TLB.
          if (l1_fifo_valid_out) begin

            // L1 hit - forward data from buffer
            if (l1_accept_cur) begin
              m_axi4_wlast       = hum_buf_wlast;
              m_axi4_wdata       = hum_buf_wdata;
              m_axi4_wstrb       = hum_buf_wstrb;
              m_axi4_wuser       = hum_buf_wuser;

              m_axi4_wvalid      = hum_buf_valid_out;
              hum_buf_ready_in   = m_axi4_wready;

              master_select_o    = l1_master_cur;

              // Detect last data beat.
              if (wlast_out) begin
                fifo_select      = 1'b0;
                w_done           = 1'b1;
                hum_buf_SN       = STORE;
              end

            // L1 miss - wait for L2
            end else if (l1_save_cur) begin
              fifo_select        = 1'b0;
              w_done             = 1'b1;
              hum_buf_SN         = WAIT_L2_BYPASS_YES;

            // L1 prefetch, prot, multi - drop data
            end else if (l1_drop_cur) begin
              fifo_select_SN     = 1'b0; // L1
              hum_buf_SN         = FLUSH;
            end
          end
        end

        WAIT_L2_BYPASS_YES : begin
          // Wait for orders from L2 TLB.
          if (l2_fifo_valid_out) begin

            // L2 hit - forward data from buffer
            if (l2_accept_cur) begin
              m_axi4_wlast       = hum_buf_wlast;
              m_axi4_wdata       = hum_buf_wdata;
              m_axi4_wstrb       = hum_buf_wstrb;
              m_axi4_wuser       = hum_buf_wuser;

              m_axi4_wvalid      = hum_buf_valid_out;
              hum_buf_ready_in   = m_axi4_wready;

              master_select_o    = l2_master_cur;

              // Detect last data beat.
              if (wlast_out) begin
                fifo_select      = 1'b1;
                w_done           = 1'b1;
                hum_buf_SN       = STORE;
              end

            // L2 miss/prefetch hit
            end else if (l2_drop_cur) begin
              fifo_select_SN     = 1'b1; // L2
              hum_buf_SN         = FLUSH;
            end

          // While we wait for orders from L2 TLB, we can still drop and accept L1 transactions.
          end else if (l1_fifo_valid_out) begin

            // L1 hit
            if (l1_accept_cur) begin
              hum_buf_SN         = BYPASS;

            // L1 prefetch/prot/multi
            end else if (l1_drop_cur) begin
              hum_buf_SN         = DISCARD;
            end
          end
        end

        FLUSH : begin
          // Flush the HUM buffer.
          hum_buf_flush    = 1'b1;

          // perform handshake with B sender
          fifo_select      = fifo_select_SP;
          b_drop_o         = 1'b1;
          if (b_done_i) begin
            hum_buf_SN     = STORE;
          end
        end

        BYPASS : begin
          // Forward one full transaction from input buffer.
          m_axi4_wlast       = axi4_wlast;
          m_axi4_wdata       = axi4_wdata;
          m_axi4_wstrb       = axi4_wstrb;
          m_axi4_wuser       = axi4_wuser;

          m_axi4_wvalid      = axi4_wvalid;
          axi4_wready        = m_axi4_wready;

          master_select_o    = l1_master_cur;

          // We have got a full transaction.
          if (axi4_wlast & axi4_wready & axi4_wvalid) begin
            fifo_select      = 1'b0;
            w_done           = 1'b1;
            hum_buf_SN       = WAIT_L2_BYPASS_YES;
          end
        end

        DISCARD : begin
          // Discard one full transaction from input buffer.
          axi4_wready        = 1'b1;

          // We have got a full transaction.
          if (axi4_wlast & axi4_wready & axi4_wvalid) begin
            // Try to perform handshake with B sender.
            fifo_select      = 1'b0;
            b_drop_o         = 1'b1;
            // We cannot wait here due to axi4_wready.
            if (b_done_i) begin
              hum_buf_SN     = WAIT_L2_BYPASS_YES;
            end else begin
              hum_buf_SN     = DISCARD_FINISH;
            end
          end
        end

        DISCARD_FINISH : begin
          // Perform handshake with B sender.
          fifo_select      = 1'b0;
          b_drop_o         = 1'b1;
          if (b_done_i) begin
            hum_buf_SN     = WAIT_L2_BYPASS_YES;
          end
        end

        WAIT_L1_BYPASS_NO : begin
          // Do not allow the forwarding of L1 hits.
          block_forwarding       = 1'b1;

          // Wait for orders from L1 TLB.
          if (l1_fifo_valid_out) begin

            // L1 hit - forward data from/through HUM buffer and refill the buffer
            if (l1_accept_cur) begin
              // Forward data from HUM buffer.
              m_axi4_wlast       = hum_buf_wlast;
              m_axi4_wdata       = hum_buf_wdata;
              m_axi4_wstrb       = hum_buf_wstrb;
              m_axi4_wuser       = hum_buf_wuser;

              m_axi4_wvalid      = hum_buf_valid_out;
              hum_buf_ready_in   = m_axi4_wready;

              master_select_o    = l1_master_cur;

              // Refill the HUM buffer. Stop when:
              // 1. Buffer full,
              // 2. Number of wlast beats in buffer > 1 (we already have the next transaction).
              stop_store         = ~hum_buf_ready_out | (n_wlast_SP > 1);
              hum_buf_valid_in   = stop_store ? 1'b0 : axi4_wvalid      ;
              axi4_wready        = stop_store ? 1'b0 : hum_buf_ready_out;

              // Detect last data beat.
              if (wlast_out) begin
                fifo_select      = 1'b0;
                w_done           = 1'b1;
                if (n_wlast_SP > 1) begin
                  hum_buf_SN     = WAIT_L1_BYPASS_YES;
                end else if (~hum_buf_ready_out | hum_buf_almost_full) begin
                  hum_buf_SN     = WAIT_L1_BYPASS_NO;
                end else begin
                  hum_buf_SN     = STORE;
                end
              end

              // Allow the forwarding of L1 hits.
              block_forwarding   = 1'b0;

            // L1 miss - wait for L2
            end else if (l1_save_cur) begin
              fifo_select        = 1'b0;
              w_done             = 1'b1;
              hum_buf_SN         = WAIT_L2_BYPASS_NO;

            // L1 prefetch, prot, multi - drop data
            end else if (l1_drop_cur) begin
              fifo_select_SN     = 1'b0; // L1
              hum_buf_SN         = FLUSH_AND_DISCARD;

              // Allow the forwarding of L1 hits.
              block_forwarding   = 1'b0;
            end
          end
        end

        WAIT_L2_BYPASS_NO : begin
          // Do not allow the forwarding of L1 hits.
          block_forwarding       = 1'b1;

          // Wait for orders from L2 TLB.
          if (l2_fifo_valid_out) begin

            // L2 hit - forward first part from HUM buffer, rest from input buffer
            if (l2_accept_cur) begin
              // Forward data from HUM buffer.
              m_axi4_wlast       = hum_buf_wlast;
              m_axi4_wdata       = hum_buf_wdata;
              m_axi4_wstrb       = hum_buf_wstrb;
              m_axi4_wuser       = hum_buf_wuser;

              m_axi4_wvalid      = hum_buf_valid_out;
              hum_buf_ready_in   = m_axi4_wready;

              master_select_o    = l2_master_cur;

              // Refill the HUM buffer. Stop when:
              // 1. Buffer full,
              // 2. Number of wlast beats in buffer > 1 (we already have the next transaction).
              stop_store         = ~hum_buf_ready_out | (n_wlast_SP > 1);
              hum_buf_valid_in   = stop_store ? 1'b0 : axi4_wvalid      ;
              axi4_wready        = stop_store ? 1'b0 : hum_buf_ready_out;

              // Detect last data beat.
              if (wlast_out) begin
                fifo_select      = 1'b1;
                w_done           = 1'b1;
                if (n_wlast_SP > 1) begin
                  hum_buf_SN     = WAIT_L1_BYPASS_YES;
                end else if (~hum_buf_ready_out | hum_buf_almost_full) begin
                  hum_buf_SN     = WAIT_L1_BYPASS_NO;
                end else begin
                  hum_buf_SN     = STORE;
                end
              end

              // Allow the forwarding of L1 hits.
              block_forwarding   = 1'b0;

            // L2 miss/prefetch hit - drop data
            end else if (l2_drop_cur) begin
              fifo_select_SN     = 1'b1; // L2
              hum_buf_SN         = FLUSH_AND_DISCARD;

              // Allow the forwarding of L1 hits.
              block_forwarding   = 1'b0;
            end
          end
        end

        FLUSH_AND_DISCARD : begin
          // Flush the HUM buffer and discard the rest of the transaction from the input buffer.
          hum_buf_flush = 1'b1;
          axi4_wready   = 1'b1;

          // We have got a full transaction.
          if (axi4_wlast & axi4_wready & axi4_wvalid) begin
            // Try to perform handshake with B sender.
            fifo_select      = fifo_select_SP;
            b_drop_o         = 1'b1;
            // We cannot wait here due to axi4_wready.
            if (b_done_i) begin
              hum_buf_SN     = STORE;
            end else begin
              hum_buf_SN     = FLUSH_AND_DISCARD_FINISH;
            end
          end
        end

        FLUSH_AND_DISCARD_FINISH : begin
          // Perform handshake with B sender.
          fifo_select   = fifo_select_SP;
          b_drop_o      = 1'b1;
          if (b_done_i) begin
            hum_buf_SN  = STORE;
          end
        end

        default: begin
          hum_buf_SN = STORE;
        end

      endcase // hum_buf_SP
    end // HUM_BUFFER_FSM

    assign b_drop_set = 1'b0;

  end else begin // HUM_BUFFER

    // register to perform the handshake with B sender
    always_ff @(posedge axi4_aclk or negedge axi4_arstn) begin
      if (axi4_arstn == 0) begin
        b_drop_o <= 1'b0;
      end else if (b_done_i) begin
        b_drop_o <= 1'b0;
      end else if (b_drop_set) begin
        b_drop_o <= 1'b1;;
      end
    end

    always_comb begin : OUTPUT_CTRL

      fifo_select   = 1'b0;
      w_done        = 1'b0;
      b_drop_set    = 1'b0;

      m_axi4_wlast  = 1'b0;
      m_axi4_wdata  =  'b0;
      m_axi4_wstrb  =  'b0;
      m_axi4_wuser  =  'b0;

      m_axi4_wvalid = 1'b0;
      axi4_wready   = 1'b0;

      if (l1_fifo_valid_out) begin
        // forward data
        if (l1_accept_cur) begin
          m_axi4_wlast  = axi4_wlast;
          m_axi4_wdata  = axi4_wdata;
          m_axi4_wstrb  = axi4_wstrb;
          m_axi4_wuser  = axi4_wuser;

          m_axi4_wvalid = axi4_wvalid;
          axi4_wready   = m_axi4_wready;

          // Simply pop from FIFO upon last data beat.
          w_done        = axi4_wlast & axi4_wvalid & axi4_wready;

        // discard entire burst
        end else if (b_drop_o == 1'b0) begin
          axi4_wready   = 1'b1;

          // Simply pop from FIFO upon last data beat. Perform handshake with B sender.
          if (axi4_wlast & axi4_wvalid & axi4_wready)
            b_drop_set  = 1'b1;
        end
      end

    end // OUTPUT_CTRL

    assign master_select_o     = l1_master_cur;
    assign l2_fifo_ready_out   = 1'b1;
    assign block_forwarding    = 1'b0;

    // unused signals
    assign hum_buf_ready_out   = 1'b0;
    assign hum_buf_valid_in    = 1'b0;
    assign hum_buf_ready_in    = 1'b0;
    assign hum_buf_valid_out   = 1'b0;
    assign hum_buf_wdata       =  'b0;
    assign hum_buf_wstrb       =  'b0;
    assign hum_buf_wlast       = 1'b0;
    assign hum_buf_wuser       =  'b0;
    assign hum_buf_in          =  'b0;
    assign hum_buf_out         =  'b0;
    assign hum_buf_flush       = 1'b0;
    assign hum_buf_almost_full = 1'b0;

    assign l2_fifo_in          =  'b0;
    assign l2_fifo_out         =  'b0;
    assign l2_fifo_valid_in    = 1'b0;
    assign l2_fifo_valid_out   = 1'b0;
    assign l2_prefetch_cur     = 1'b0;
    assign l2_hit_cur          = 1'b0;
    assign l2_id_cur           =  'b0;
    assign l2_master_cur       = 1'b0;
    assign l2_accept_cur       = 1'b0;
    assign l2_drop_cur         = 1'b0;

    assign l2_req              = 1'b0;

    assign fifo_select_SN      = 1'b0;
    assign fifo_select_SP      = 1'b0;

    assign stop_store          = 1'b0;
    assign n_wlast_SP          =  'b0;
    assign wlast_in            = 1'b0;
    assign wlast_out           = 1'b0;

  end // HUM_BUFFER

  endgenerate

endmodule

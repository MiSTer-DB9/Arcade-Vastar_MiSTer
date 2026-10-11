//============================================================================
//
//  Orca OVG-40c video board (Dog Fight prototype on the Vastar CPU board;
//  the Zodiack-family games use the same board)
//  Copyright (C) 2026 Rodimus
//
//  MAME reference: orca40c.cpp, vastar.cpp (dogfightp), zodiack.cpp
//  Layers: background 1bpp chars (no scroll), foreground 2bpp chars with a
//  scroll value per column (transparent pen 0), 8 bullets (one white dot each),
//  8 sprites 16x16 2bpp. Drawn back to front in that order, like MAME.
//
//============================================================================

module Vastar_OVG40C
(
	input         clk_49m,
	input         reset,          // active low

	// main CPU side: 9000-93FF attributes / sprites / bullets / RAM, A000-A3FF fg, B000-B3FF bg
	input  [15:0] cpu_A,
	input   [7:0] cpu_Dout,
	input         cpu_mem_valid,
	input         cpu_wr,
	output        cs,
	output  [7:0] cpu_Din,

	// render: one line per trigger into the write page, read back from the other page
	input         render_start,
	input   [7:0] rline,          // MAME bitmap line being rendered
	input         lb_page,
	input   [7:0] disp_x,         // MAME bitmap column being displayed
	input         blank,
	input         flip,           // board flip (MAME m_flip_screen)
	input         percuss,        // MAME set_percuss_hardware: sprites / bullets follow the flip in Y

	// ROM download: gfx region (0x3000) and colour PROMs (0x40)
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_data,
	input         ioctl_wr,
	input         gfx_cs,
	input         prom_cs,

	output  [4:0] red, green, blue
);

//----------------------------------------------------------- CPU side -----------------------------------------------------------//

wire cs_obj = cpu_mem_valid & (cpu_A[15:10] == 6'b100100);    // 9000-93FF
wire cs_fg  = cpu_mem_valid & (cpu_A[15:10] == 6'b101000);    // A000-A3FF
wire cs_bg  = cpu_mem_valid & (cpu_A[15:10] == 6'b101100);    // B000-B3FF
assign cs = cs_obj | cs_fg | cs_bg;

reg  [9:0] obj_raddr, fg_raddr, bg_raddr;
wire [7:0] obj_q, fg_q, bg_q, obj_cq, fg_cq, bg_cq;

dpram_dc #(.widthad_a(10)) obj_ram (
	.clock_a(clk_49m), .address_a(cpu_A[9:0]), .data_a(cpu_Dout), .wren_a(cs_obj & cpu_wr), .q_a(obj_cq),
	.clock_b(clk_49m), .address_b(obj_raddr), .q_b(obj_q));

dpram_dc #(.widthad_a(10)) fg_ram (
	.clock_a(clk_49m), .address_a(cpu_A[9:0]), .data_a(cpu_Dout), .wren_a(cs_fg & cpu_wr), .q_a(fg_cq),
	.clock_b(clk_49m), .address_b(fg_raddr), .q_b(fg_q));

dpram_dc #(.widthad_a(10)) bg_ram (
	.clock_a(clk_49m), .address_a(cpu_A[9:0]), .data_a(cpu_Dout), .wren_a(cs_bg & cpu_wr), .q_a(bg_cq),
	.clock_b(clk_49m), .address_b(bg_raddr), .q_b(bg_q));

assign cpu_Din = cs_obj ? obj_cq : cs_fg ? fg_cq : bg_cq;

//------------------------------------------------------------ ROMs --------------------------------------------------------------//

// download window starts at 0x14400 (rtl/ram_rom/rom_loader.sv): low 14 bits 0400 -> gfx address 0000
// gfx region as MAME lays it out: 0000 bg chars (1bpp), 0800 sprite plane 0, 1000 fg char plane 0,
// 1800 sprite plane 1, 2000 fg char plane 1 (charlayout_2 planes are 512*8*8 bits = 0x1000 bytes apart)
reg  [13:0] gfx_addr;
wire  [7:0] gfx_q;
dpram_dc #(.widthad_a(14)) gfx_rom (
	.clock_a(clk_49m), .address_a(ioctl_addr[13:0] - 14'h0400), .data_a(ioctl_data), .wren_a(ioctl_wr & gfx_cs),
	.clock_b(clk_49m), .address_b(gfx_addr), .q_b(gfx_q));

reg [7:0] prom[64];
always @(posedge clk_49m) if (ioctl_wr & prom_cs) prom[ioctl_addr[5:0]] <= ioctl_data;

//------------------------------------------------------------ Line buffer -------------------------------------------------------//

// one byte per pixel: [7] bullet (white), [5:0] colour PROM index
reg  [7:0] lb_waddr;
reg  [7:0] lb_wdata;
reg        lb_we = 1'b0;
wire [7:0] lb_q;
dpram_dc #(.widthad_a(9)) line_buf (
	.clock_a(clk_49m), .address_a({lb_page, lb_waddr}), .data_a(lb_wdata), .wren_a(lb_we),
	.clock_b(clk_49m), .address_b({~lb_page, disp_x}), .q_b(lb_q));

//------------------------------------------------------------ Renderer ----------------------------------------------------------//

// Tilemaps flip as a whole (MAME TILEMAP_FLIPX | FLIPY): the line is rendered unflipped from source line
// 255 - rline and written mirrored. Sprites and bullets are placed in screen coordinates as MAME does.
wire [7:0] tline = flip ? 8'd255 - rline : rline;
function [7:0] tx(input [7:0] x);
	tx = flip ? 8'd255 - x : x;
endfunction

localparam S_IDLE = 4'd0, S_BG = 4'd1, S_FG = 4'd2, S_BUL = 4'd3, S_SPR = 4'd4;
reg  [3:0] state = S_IDLE;
reg  [4:0] step;              // sub-step within the current item
reg  [4:0] col;               // tile column / sprite or bullet index
reg  [3:0] px;                // pixel within the item
reg  [7:0] code, attr, scroll, p0, p1, b51;
reg  [7:0] sy, sx;
reg  [8:0] bx;                // bullet x (MAME byte 3 + 7 can pass 255: clipped, not wrapped)
reg  [3:0] srow;
reg        sfx, sfy;
reg  [2:0] scol;
wire [7:0] fy  = tline + scroll;
wire [7:0] sdy = rline - sy;      // sprite row on this line (on the sprite when < 16)

always @(posedge clk_49m) begin
	lb_we <= 1'b0;
	if (!reset) state <= S_IDLE;
	else case (state)
	S_IDLE: if (render_start) begin state <= S_BG; col <= 5'd0; step <= 5'd0; end

	// background: code = bg[row * 32 + col], colour = attr[col * 2 + 1] bits 6-4, 1bpp from 0000, always opaque
	S_BG: begin
		step <= step + 5'd1;
		case (step)
		5'd0: begin bg_raddr <= {tline[7:3], col}; obj_raddr <= {4'd0, col, 1'b1}; end
		5'd2: begin code <= bg_q; attr <= obj_q; end
		5'd3: gfx_addr <= {3'b000, code, tline[2:0]};
		5'd5: begin p0 <= gfx_q; px <= 4'd0; end
		5'd6: begin
			lb_waddr <= tx({col, px[2:0]});
			lb_wdata <= {2'b00, 2'b10, p0[3'd7 - px[2:0]], attr[6:4]};    // pen 0 -> PROM 20+c, pen 1 -> 28+c
			lb_we    <= 1'b1;
			px       <= px + 4'd1;
			if (px[2:0] == 3'd7) begin
				step <= 5'd0;
				col  <= col + 5'd1;
				if (col == 5'd31) state <= S_FG;
			end else step <= 5'd6;
		end
		default: ;
		endcase
	end

	// foreground: scroll = attr[col * 2], colour = attr[col * 2 + 1] bits 2-0, code = fg[row * 32 + col] on
	// line + scroll, planes at 1000 (MSB) and 2000, pen 0 transparent
	S_FG: begin
		step <= step + 5'd1;
		case (step)
		5'd0: obj_raddr <= {4'd0, col, 1'b0};
		5'd1: obj_raddr <= {4'd0, col, 1'b1};
		5'd2: scroll <= obj_q;
		5'd3: begin attr <= obj_q; fg_raddr <= {fy[7:3], col}; end
		5'd5: code <= fg_q;
		5'd6: gfx_addr <= {3'b010, code, fy[2:0]};
		5'd7: gfx_addr <= {3'b100, code, fy[2:0]};
		5'd8: p0 <= gfx_q;
		5'd9: begin p1 <= gfx_q; px <= 4'd0; end
		5'd10: begin
			if (p0[3'd7 - px[2:0]] | p1[3'd7 - px[2:0]]) begin
				lb_waddr <= tx({col, px[2:0]});
				lb_wdata <= {2'b00, 1'b0, attr[2:0], p0[3'd7 - px[2:0]], p1[3'd7 - px[2:0]]};
				lb_we    <= 1'b1;
			end
			px <= px + 4'd1;
			if (px[2:0] == 3'd7) begin
				step <= 5'd0;
				col  <= col + 5'd1;
				if (col == 5'd31) begin state <= S_BUL; col <= 5'd0; end
			end else step <= 5'd10;
		end
		default: ;
		endcase
	end

	// bullets (MAME draw_bullets): 8 entries of 4 bytes at 9060, x = byte 3 + 7, y = byte 1 (255 - y unless
	// flipped percuss hardware); a 7x1 pattern from char ROM byte 0051: bit 4 then bit 0 six times
	S_BUL: begin
		step <= step + 5'd1;
		case (step)
		5'd0: begin gfx_addr <= 14'h0051; obj_raddr <= {5'b00011, col[2:0], 2'd1}; end
		5'd1: obj_raddr <= {5'b00011, col[2:0], 2'd3};
		5'd2: begin b51 <= gfx_q; sy <= (flip & percuss) ? obj_q : 8'd255 - obj_q; end
		5'd3: begin bx <= {1'b0, obj_q} + 9'd7; px <= 4'd0; end
		5'd4: begin
			if (sy == rline && (px == 4'd0 ? b51[4] : b51[0]) && bx + {6'd0, px[2:0]} < 9'd256) begin
				lb_waddr <= bx[7:0] + {5'd0, px[2:0]};
				lb_wdata <= 8'h80;
				lb_we    <= 1'b1;
			end
			px <= px + 4'd1;
			if (px == 4'd6) begin
				step <= 5'd0;
				col  <= col + 5'd1;
				if (col[2:0] == 3'd7) begin state <= S_SPR; col <= 5'd7; end
			end else step <= 5'd4;
		end
		default: ;
		endcase
	end

	// sprites (MAME draw_sprites, last entry first so entry 0 lands on top): 4 bytes each at 9040,
	// x = 240 - byte 3, y = 240 - byte 0, code = byte 1 bits 5-0, flipx = !bit 6, flipy = bit 7,
	// colour = byte 2 bits 2-0; flipped percuss hardware: y = 240 - y, flipy inverted. Planes 0800 / 1800.
	S_SPR: begin
		step <= step + 5'd1;
		case (step)
		5'd0: obj_raddr <= {5'b00010, col[2:0], 2'd0};
		5'd1: obj_raddr <= {5'b00010, col[2:0], 2'd1};
		5'd2: begin obj_raddr <= {5'b00010, col[2:0], 2'd2}; sy <= 8'd240 - obj_q; end
		5'd3: begin obj_raddr <= {5'b00010, col[2:0], 2'd3}; code <= obj_q; end
		5'd4: begin
			scol <= obj_q[2:0];
			if (flip & percuss) sy <= 8'd240 - sy;
			sfx <= ~code[6];
			sfy <= code[7] ^ (flip & percuss);
		end
		5'd5: begin
			sx <= 8'd240 - obj_q;
			srow <= sdy[3:0];
			if (sdy >= 8'd16) step <= 5'd15;                       // not on this line
		end
		5'd6: begin
			// byte = 0800 + code * 32 + row (rows 8-15 at +16), +8 for pixels 8-15
			gfx_addr <= {3'b001, code[5:0], (srow ^ {4{sfy}}) >= 4'd8, 1'b0, (srow[2:0] ^ {3{sfy}})};
		end
		5'd7: gfx_addr <= {3'b001, code[5:0], (srow ^ {4{sfy}}) >= 4'd8, 1'b1, (srow[2:0] ^ {3{sfy}})};
		5'd8: begin p0 <= gfx_q; gfx_addr <= {3'b011, code[5:0], (srow ^ {4{sfy}}) >= 4'd8, 1'b0, (srow[2:0] ^ {3{sfy}})}; end
		5'd9: begin b51 <= gfx_q; gfx_addr <= {3'b011, code[5:0], (srow ^ {4{sfy}}) >= 4'd8, 1'b1, (srow[2:0] ^ {3{sfy}})}; end
		5'd10: p1 <= gfx_q;          // plane 1, pixels 0-7
		5'd11: begin attr <= gfx_q; px <= 4'd0; end   // plane 1, pixels 8-15
		5'd12: begin
			begin
				reg [3:0] c;
				reg       b0, b1;
				reg [8:0] x;
				c  = px ^ {4{sfx}};
				b0 = c[3] ? b51[3'd7 - c[2:0]] : p0[3'd7 - c[2:0]];
				b1 = c[3] ? attr[3'd7 - c[2:0]] : p1[3'd7 - c[2:0]];
				x  = {1'b0, sx} + {5'd0, px};
				// MAME sx is signed (240 - byte, -15..240): a byte above 240 places the sprite left of 0
				if ((b0 | b1) && (sx < 8'd241 ? x < 9'd256 : x >= 9'd256)) begin
					lb_waddr <= x[7:0];
					lb_wdata <= {2'b00, 1'b0, scol, b0, b1};
					lb_we    <= 1'b1;
				end
			end
			px <= px + 4'd1;
			if (px == 4'd15) step <= 5'd15;
			else step <= 5'd12;
		end
		5'd15: begin
			step <= 5'd0;
			col  <= col - 5'd1;
			if (col[2:0] == 3'd0) state <= S_IDLE;
		end
		default: ;
		endcase
	end

	default: state <= S_IDLE;
	endcase
end

//------------------------------------------------------------ Colours -----------------------------------------------------------//

// MAME orca_ovg_40c palette_init: R / G bits 2-0 / 5-3 at 0x21 / 0x47 / 0x97, B bits 7-6 at 0x47 / 0x97
wire [7:0] pv = prom[lb_q[5:0]];
wire [7:0] r8 = (pv[0] ? 8'h21 : 8'h00) + (pv[1] ? 8'h47 : 8'h00) + (pv[2] ? 8'h97 : 8'h00);
wire [7:0] g8 = (pv[3] ? 8'h21 : 8'h00) + (pv[4] ? 8'h47 : 8'h00) + (pv[5] ? 8'h97 : 8'h00);
wire [7:0] b8 = (pv[6] ? 8'h47 : 8'h00) + (pv[7] ? 8'h97 : 8'h00);

assign red   = blank ? 5'd0 : lb_q[7] ? 5'h1F : r8[7:3];
assign green = blank ? 5'd0 : lb_q[7] ? 5'h1F : g8[7:3];
assign blue  = blank ? 5'd0 : lb_q[7] ? 5'h1F : b8[7:3];

endmodule

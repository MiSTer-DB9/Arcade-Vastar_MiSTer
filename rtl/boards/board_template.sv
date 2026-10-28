//============================================================================
//  board_template.sv - start a new Vastar-core board by copying this file (NOT in files.qip, never compiled).
//  Copyright (C) 2026 Rodimus
//
//  Boards never instantiate a CPU, sound chip, ROM store or board RAM. They live ONCE in the dispatcher
//  rtl/vastar_dispatcher.sv: Z80s z80_0 (main) / z80_1 (sub / audio) on z80r_* buses, AY-3-8910 ay_0 (ayr_i_t /
//  ayio_o_t), the ROM blocks (program, sub program, fg / bg tiles, sprites, colour PROMs, OVG-40c gfx + PROMs; loaded by
//  ioctl index 0 address through rtl/ram_rom/rom_loader.sv) and the board RAM pool pr 0-6 (4K x 3, 2K, 256, 1K, 512;
//  ram_pool_pkg). The CPU board rtl/boards/vastar/Vastar_CPU.sv carries the OVG-40c video board and drives every pool
//  port.
//  To add a board: copy this file to rtl/boards/<board>/<board>.sv, add it to files.qip + verilator/Makefile, instance
//  it from Vastar_CPU.sv (or the dispatcher), put its requests on the pool blocks there (muxed by the board flags) and
//  tie what it doesn't use to '0. A RAM bigger than its block = grow the block, never a private dpram_dc. ROM images:
//  load decode by ioctl index and address only, NEVER by a game flag. A RAM / chip that truly can't pool =
//  "// POOL-EXCEPTION: <reason>" on its instance line + a Pool contract row (Claude/ vault note).
//  verilator/common/pool_check.sh (POOL_MODS) enforces it.
//============================================================================

module board_template
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,          // core reset | this board inactive
    input  logic        pause,

    output chip_pool_pkg::z80r_i_t [1:0] z80_i,
    input  chip_pool_pkg::z80r_o_t [1:0] z80_o,
    output chip_pool_pkg::ayr_i_t        ay_0_i,
    input  chip_pool_pkg::ayio_o_t       ay_0_o,

    output logic [14:0] main_rom_a,     // shared ROM block read port
    input  logic  [7:0] main_rom_d,

    output ram_pool_pkg::pram_i_t  [6:0] pr_i,
    input  ram_pool_pkg::pram_o_t  [6:0] pr_o,

    output logic signed [15:0] audio
);

assign z80_i      = '0;
assign ay_0_i     = '0;
assign main_rom_a = 15'd0;
assign pr_i       = '0;
assign audio      = 16'sd0;

endmodule

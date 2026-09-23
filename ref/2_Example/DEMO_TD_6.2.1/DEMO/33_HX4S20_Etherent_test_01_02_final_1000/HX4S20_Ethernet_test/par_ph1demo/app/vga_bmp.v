module vga_bmp
(
	input					sys_clk,
	input				   reset,

	output		 	   VGA_HSYNC,
	output 		 	   VGA_VSYNC,

	output    [11:0]  VGA_D
);

reg  			clk25M;

wire [ 7:0]	rgb;
wire [14:0]	addr;

always @(posedge sys_clk or negedge reset) begin
	if (!reset)
		clk25M <= 0;
	else
		clk25M <= ~clk25M;
end

rom_bmp u_rom_bmp (
	.addra 	(addr),
	.clka 		(clk25M),
	.doa 			(rgb)
);

vga_disp u_vga_disp(
	.clk25M 	   (clk25M),
	.reset_n		(reset),
	.rgb			(rgb),
	.VGA_HSYNC	(VGA_HSYNC),
	.VGA_VSYNC	(VGA_VSYNC),
	.addr			(addr),
	.VGA_D		(VGA_D)
);

endmodule



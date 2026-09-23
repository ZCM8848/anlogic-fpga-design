//硬件实验使用程序，加入了彩条显示，删去了读取rom信息
module vgaV	
(
	input	clk,
	input	reset_n,

	output VGA_HSYNC,
	output VGA_VSYNC,

	output reg	[2:0] VGA_D
);		
	reg	[9:0]	hcnt,	vcnt;		

	reg	r,	g,	b;
	reg	hs,	vs;
	wire [2:0] rgb;


	wire [10:0] x= hcnt;
	wire [10:0] y= vcnt;
	assign VGA_VSYNC = vs;
	assign VGA_HSYNC = hs;

	wire display_enable;

	reg clk25M;

	assign display_enable = (x<640 && y<480);
	assign rgb = x[8:6] + y[8:6];


	always @(posedge clk or negedge reset_n)
		if (!reset_n)
			clk25M <= 0;
		else
			clk25M <= ~clk25M;
			
	always @(posedge clk25M or negedge reset_n)			//水平扫描计数器
			if(!reset_n)
					hcnt <= 0;
			else
					begin
							if (hcnt < 800)
									hcnt <= hcnt + 1'b1;
							else
									hcnt <= 0;
					end
			
	always @(posedge clk25M or negedge reset_n)			//垂直扫描计数器
			if(!reset_n)
					vcnt <= 0;
			else
					begin
							if (hcnt == 640 + 8)
									begin
											if (vcnt < 525)
													vcnt <= vcnt +1'b1;
											else
													vcnt <= 0;
									end
					end
			
	always @(posedge clk25M or negedge reset_n)			//场同步信号发生
			if(!reset_n)
					hs	<=	1;
			else
					begin
							if( (hcnt >=640+8+8) & (hcnt < 640 +8 +8 +96) )
									hs <= 1'b0;
							else
									hs <= 1'b1;
					end
			
	always @(vcnt or reset_n)							//行同步信号发生
			if(!reset_n)
					vs	<=	1;
			else
					begin
							if( (vcnt >= 480 + 8 + 2) &&(vcnt < 480 + 8 + 2 +2) )
									vs	<=	1'b0;
							else
									vs	<=	1'b1;
					end
			
	always @(posedge clk25M or negedge reset_n)
			if(!reset_n)
					begin
						VGA_D <= 0;
					end
			else
			begin
					if (hcnt < 640 & vcnt < 480 && display_enable)		//扫描终止
							begin
								VGA_D[0] <= rgb[0];
								VGA_D[1] <= rgb[1];
								VGA_D[2] <= rgb[2];
							end
					else
							begin
								VGA_D <= 0;
							end
			end
				
endmodule 

module ball_top(
	clk,
	rst,
	ps2_clk,
	ps2_dat,
	r,
	g,
	b,
	hs,
	vs,
	spk_kk
);

input 	clk;
input 	rst;
input	ps2_clk;
input 	ps2_dat;
output 	r;
output 	g;
output 	b;
output 	hs;
output 	vs;
output 	spk_kk;

wire	[23:0] q;
wire	CLK1m;
wire	[10:0] TN;
wire	aa;
wire	[4:0] INX;
wire	[10:0] DOUT1;
wire	clk25m;
wire	[9:0] DOUT;
wire	[7:0] Q1;
wire	[199:0] rgbin;
wire	[5:0] seed;
wire	clk1k;
wire	PM;
wire	[7:0] cnt8_adr;
wire    lock;
wire    clk20m;
vga_clk uinst(
.clk0_out(clk25m), 
.clk1_out(clk20m),
.reset(~rst), 
.extlock(lock), 
.refclk(clk)
);


  count	u0(
	.CLK(clk20m),
	.Q(q));
    
    
  DIV_CLK u1(
    .clkin(clk),
   .clk1MHz(CLK1m),
   .clk1KHz(clk1k)); 
   
SPKER	u2(
	.CLK(CLK1m),
	.TN(TN),
	.FOUT(spk_kk));

F_CODE	u3(
	.A(aa),
	.CODE(),
	.H(),
	.INX(INX),
	.TO(TN));
rom_quanbu	u4(
    .addra(DOUT1),
	.clka(clk20m),
	.doa(rgbin));

rom1	u5(
	.addra(DOUT),
	.clka(clk25m),
	.doa(Q1));

	
cnt26	u6(
	.CLK(clk25m),
	.Q(seed));
ball3	u7(
	.clk_25m(clk25m),
	.clk_count(q[18]),
	.rst(rst),
	.ps2_clk(ps2_clk),
	.ps2_dat(ps2_dat),
	.q(Q1),
	.rgbin(rgbin),
	.seed(seed),
	.r(r),
	.g(g),
	.b(b),
	.hs(hs),
	.vs(vs),
	.aa(aa),
	.DOUT(DOUT),
	.DOUT1(DOUT1));


FDIV	u8(
	.CLK(clk1k),
	.PM(PM));


CNT138T	u9(
	.CLK(PM),
	.CNT8(cnt8_adr));


music2	u10(
	.clka(PM),
	.addra(cnt8_adr),
	.doa(INX));
endmodule

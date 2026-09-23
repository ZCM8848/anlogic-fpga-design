module cnt10_disp
(
	input CLOCK,
	input [2:0] KEY,
	input [3:0] SW,
	output [7:0] SEL,
	output [7:0] DIG
);

localparam LEN = 25;
wire en,load_n,reset_n;
wire [3:0] d;
wire cout;
wire clk;
reg [6:0] LED7S;
reg [3:0] cnt;
reg [LEN-1:0] div;

assign {en,load_n,reset_n} = KEY;
assign DIG = {~cout,LED7S};
assign d = SW;
assign clk = div[LEN-1];
assign SEL = 8'b1111_1110;

always @(posedge clk,negedge reset_n)
	if(!reset_n)
		cnt <= 0;
	else if(en)
		if(!load_n)
			cnt <= d;
		else if(cnt < 9)
			cnt <= cnt + 1'b1;
		else
			cnt <= 0;

assign cout = (cnt==9);	

		
always @*
	case(cnt)
		4'b0000	:	LED7S	<=	7'b1000_000;//7'b0111_111;
		4'b0001	:	LED7S	<=	7'b1111_001;//7'b0000_110;
		4'b0010	:	LED7S	<=	7'b0100_100;//7'b1011_011;
		4'b0011	:	LED7S	<=	7'b0110_000;//7'b1001_111;
		4'b0100	:	LED7S	<=	7'b0011_001;//7'b1100_110;
		4'b0101	:	LED7S	<=	7'b0010_010;//7'b1101_101;
		4'b0110	:	LED7S	<= 7'b0000_010;//7'b1111_101;
		4'b0111	:	LED7S	<=	7'b1111_000;//7'b0000_111;
		4'b1000	:	LED7S	<=	7'b0000_000;//7'b1111_111;
		4'b1001	:	LED7S	<=	7'b0010_000;//7'b1101_111;
		4'b1010	:	LED7S	<=	7'b0001_000;//7'b1110_111;
		4'b1011	:	LED7S	<=	7'b0000_011;//7'b1111_100;
		4'b1100	:	LED7S	<=	7'b1000_110;//7'b0111_001;
		4'b1101	:	LED7S	<=	7'b0100_001;//7'b1011_110;
		4'b1110	:	LED7S	<=	7'b0000_110;//7'b1111_001;
		4'b1111	:	LED7S	<=	7'b0001_110;//7'b1110_001;
		default	:	LED7S	<=	7'b1000_000;//7'b0111_111;	
	endcase	
	

always @(posedge CLOCK,negedge reset_n)
	if(!reset_n)
		div <= 0;
	else
		div <= div + 1'b1;
	
endmodule 
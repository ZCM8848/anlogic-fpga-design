module CODE3 (input [7:0] DIN,	output reg [3:0] KEY);
		always @(DIN)
				begin
						case	(DIN)
								8'b00010110	:	KEY <= 	4'b0001;
								8'b00011110	:	KEY	<= 	4'b0010;
								
								8'b00100110	:	KEY <= 	4'b0011;
								8'b00100101	:	KEY	<= 	4'b0100;
								
								8'b00101110	:	KEY	<=	4'b0101;
								8'b00110110	:	KEY	<=	4'b0110;
								
								8'b00111101	:	KEY	<=	4'b0111;
								8'b00111110	:	KEY	<=	4'b1000;
								
								8'b01000101	:	KEY	<=	4'b1001;
								default :					KEY	<=	4'b0000;
						endcase
				end
endmodule 
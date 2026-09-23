module F_CODE (INX, CODE, H, TO);
		input [3:0]	INX;
		output [3:0] CODE;
		output	H;
		output 	[10:0] TO;
		reg	[10:0]	TO;
		reg	[3:0]	CODE;
		reg	H;
		always @(INX)
				begin
						case (INX)			//译码电路，查表方式，控制音调的预置
								4'd0	:	begin	
												TO	<=	11'H7FF;	
												CODE <= 0;
												H <= 0;end
								4'd1	:	begin
												TO	<=	11'H305;	
												CODE <= 1;
												H <= 0;	end
								4'd2	:	begin
												TO	<=	11'H390;	
												CODE <= 2;
												H <= 0;end			
								4'd3	:	begin
												TO	<=	11'H40C;	
												CODE <= 3;
												H <= 0;end		
								4'd4	:	begin
												TO	<=	11'H45C;	
												CODE <= 4;
												H <= 0;											
										end
								4'd5	:	begin
												TO	<=	11'H4AD;	
												CODE <= 5;
												H <= 0;											
										end	
								4'd6	:	begin
												TO	<=	11'H50A;	
												CODE <= 6;
												H <= 0;											
										end									
								4'd7	:	begin
												TO	<=	11'H55C;	
												CODE <= 7;
												H <= 0;											
										end	
								4'd8	:	begin
												TO	<=	11'H582;	
												CODE <= 1;
												H <= 1;											
										end
								4'd9	:	begin
												TO	<=	11'H5C8;	
												CODE <= 2;
												H <= 1;											
										end
								4'd10	:	begin
													TO	<=	11'H606;	
													CODE <= 3;
													H <= 1;											
											end	
								4'd11	:	begin
													TO	<=	11'H640;	
													CODE <= 4;
													H <= 1;											
											end	
								4'd12	:	begin
													TO	<=	11'H656;	
													CODE <= 5;
													H <= 1;											
											end	
								4'd13	:	begin
													TO	<=	11'H684;	
													CODE <= 6;
													H <= 1;											
											end
								4'd14	:	begin
													TO	<=	11'H69A;	
													CODE <= 7;
													H <= 1;											
											end		
								4'd15	:	begin
													TO	<=	11'H6C0;	
													CODE <= 1;
													H <= 1;											
											end		
								default : 
											begin
													TO	<=	11'H6C0;	
													CODE <= 1;
													H <= 1;														
											end
						endcase
				end
endmodule 
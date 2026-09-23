/******************************FILE HEAD**********************************
 * file_name         : Char2Num.v
 * function          : 若Char为字符0~9，将之转化为数字0~9
 * author            : Fervent
 * version & date    : 2021/10/14 & v1.0
 *************************************************************************/
module Char2Num(
	input 		[7:0]	Char,
	output		[3:0]	Num,
	output	reg			isNum
);

always@(*)begin
	case(Char)
		"0": isNum <= 1;
		"1": isNum <= 1;
		"2": isNum <= 1;
		"3": isNum <= 1;
		"4": isNum <= 1;
		"5": isNum <= 1;
		"6": isNum <= 1;
		"7": isNum <= 1;
		"8": isNum <= 1;
		"9": isNum <= 1;
		default: isNum <= 0;
	endcase
end

assign Num = isNum? Char - "0" : 4'hff;

endmodule
//END OF Char2Num.v FILE***************************************************


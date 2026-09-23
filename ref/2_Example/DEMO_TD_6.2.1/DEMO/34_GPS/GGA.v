/******************************FILE HEAD**********************************
 * file_name         : parseGGA.v
 * function          : 解析xxGGA报文，获取UTC时间、经纬度、海拔
 * author            : Fervent
 * version & date    : 2024/11/11 & v1.0
 *************************************************************************/
module GGA(
	input				rx_done_toUart,	//整个模块由rx_done_toUart驱动
	input		[7:0]	rddat_toUart,
	output	reg 		rx_done,		//接收指令结束，上升沿对齐'\n'字符出现时刻，下降沿对齐$xxGGA后面的','的出现时刻的下一时刻
	output	reg	[4:0]	hh,				//UTC时间，整数，时  0~24
	output	reg	[5:0]	mm,				//UTC时间，整数，分  0~59
	output	reg	[5:0]	ss,				//UTC时间，整数，秒  0~59
	output	reg	[6:0]	ss2,			//UTC时间，小数，秒  2位小数，0~99
	output	reg	[6:0]	lat,			//纬度  整数部分，度  0~90
	output	reg	[5:0]	lat2,			//纬度  整数部分，分  0~59
	output	reg	[16:0]	lat3,			//纬度  小数部分，分  5位小数,0~99999
	output	reg			NS,				//区分南北纬，北纬标为1，南纬标为0
	output	reg	[7:0]	lon,			//经度  整数部分，度  0~180
	output	reg	[5:0]	lon2,			//经度  整数部分，分  0~59
	output	reg	[16:0]	lon3,			//经度  小数部分，分  5位小数，0~99999
	output	reg			EW,				//区分东西经，东经标为1，西经标为0
	output	reg [13:0]	alt,			//海拔  整数部分，m
	output	reg [3:0]	alt2			//海拔  小数部分，一位小数  0~9
);
//xxGGA格式: $xxGGA,time,lat,NS,lon,EW,quality,numSV,HDOP,alt,altUnit,sep,sepUnit,diffAge,diffStation*cs<CR><LF>
//time格式: hhmmss.ss
//lat格式: ddmm.mmmmm
//lon格式: dddmm.mmmmm
//alt格式: numeric，一位小数

reg		[4:0]	cntField;		//当前读取第几个域，以','分隔
reg 	[3:0]	cntChar;		//当前读取域中的第几个字符

reg				start	= 1'b0;	//NMEA报文的接收标志，以$开始，到\n结束
reg		[7:0]	charBuffer;
reg		[1:0]	corrNum	= 2'd0;	//比对是否为xxGGA，当corrNum=3时，表示"GGA"字符通过测试，该条报文即xxGGA

wire	[3:0]	num;			//若charBuffer为字符0~9，则将之转换为数字0~9
wire			isnum;

reg				afterDot;		//判断是否是"."后面的数字，在解析海拔时用到

//将字符0~9转换为数字0~9
Char2Num Char2Num_inst(
	.Char(charBuffer),
	.Num(num),
	.isNum(isnum)
);

always @(posedge rx_done_toUart) begin
	charBuffer	<= rddat_toUart;

	//-----------------------接收NMEA报文数据-----------------------------
	if(rddat_toUart == "$") begin			//接收到$，标志着NMEA数据的起始
		start		<= 1'b1;
		cntField	<= 5'd0;
		cntChar		<= 4'd0;
		corrNum		<= 2'd0;
	end
	else if(start) begin
		if(rddat_toUart == "\n") begin		//收到\n，标志NMEA报文结束
			start		<= 1'b0;
			rx_done		<= 1'b1;
		end
		else if(rddat_toUart == "," || 
				rddat_toUart == "*") begin	//收到','或'*'，为域的分隔符
			cntField	<= cntField + 1'b1;
			cntChar		<= 4'd0;
		end
		else begin							//收到其他字符
			cntChar		<= cntChar + 1'b1;
		end
	end
	else begin
		start		<= 1'b0;
		cntField	<= 5'd0;
		cntChar		<= 4'd0;
		corrNum		<= 2'd0;
	end
	
	//------------------------判断是否为xxGGA----------------------------
	if(cntField == 5'd0) begin
		if(cntChar == 4'd3 && charBuffer == "G") begin
			corrNum <= corrNum + 1'b1;
		end
		else if(cntChar == 4'd4 && charBuffer == "G") begin
			corrNum <= corrNum + 1'b1;
		end
		else if(cntChar == 4'd5 && charBuffer == "A") begin
			corrNum <= corrNum + 1'b1;
		end
	end
	if(corrNum == 2'd3) begin	//检测到是"xxGGA"，开启解析
		rx_done <= 1'b0;
		corrNum	<= 2'b0;
	end
	
	//---------------------------解析xxGGA------------------------------
	if(rx_done == 1'b0) begin
		//解析UTC时间
		if(cntField == 5'd1) begin
			if(cntChar == 4'd1) begin		//UTC-hh
				hh	<= num*4'd10;
			end
			else if(cntChar == 4'd2) begin
				hh	<= hh + num;
			end
			else if(cntChar == 4'd3) begin	//UTC-mm
				mm	<= num*4'd10;
			end
			else if(cntChar == 4'd4) begin
				mm	<= mm + num;
			end
			else if(cntChar == 4'd5) begin	//UTC-ss
				ss	<= num*4'd10;
			end
			else if(cntChar == 4'd6) begin
				ss	<= ss + num;
			end
			else if(cntChar == 4'd8) begin	//UTC-.ss
				ss2	<= num*4'd10;
			end
			else if(cntChar == 4'd9) begin
				ss2	<= ss2 + num;
			end
		end
		
		//解析纬度
		if(cntField == 5'd2) begin
			if(cntChar == 4'd1) begin		//lat-dd
				lat		<= num*4'd10;
			end
			else if(cntChar == 4'd2) begin
				lat		<= lat + num;
			end
			else if(cntChar == 4'd3) begin	//lat-mm
				lat2	<= num*4'd10;
			end
			else if(cntChar == 4'd4) begin
				lat2	<= lat2 + num;
			end
			else if(cntChar == 4'd6) begin	//lat-.mmmmm
				lat3	<= num;
			end
			else if(cntChar == 4'd7 || cntChar == 4'd8 ||
					cntChar == 4'd9 || cntChar == 4'd10) begin
				lat3	<= lat3*4'd10 + num;
			end
		end
		if(cntField == 5'd3 && cntChar == 4'd1) begin	//NS
			if(charBuffer == "N") begin
				NS	<= 1'b1;
			end
			else begin
				NS	<= 1'b0;
			end
		end
		
		//解析经度
		if(cntField == 5'd4) begin
			if(cntChar == 4'd1) begin		//lon-ddd
				lon		<= num;
			end
			else if(cntChar == 4'd2 || cntChar == 4'd3) begin
				lon		<= lon*4'd10 + num;
			end
			else if(cntChar == 4'd4) begin	//lon-mm
				lon2	<= num*4'd10;
			end
			else if(cntChar == 4'd5) begin
				lon2	<= lon2 + num;
			end
			else if(cntChar == 4'd7) begin	//lon-.mmmmm
				lon3	<= num;
			end
			else if(cntChar == 4'd8 || cntChar == 4'd9 ||
					cntChar == 4'd10 || cntChar == 4'd11) begin
				lon3	<= lon3*4'd10 + num;
			end
		end
		if(cntField == 5'd5 && cntChar == 4'd1) begin	//EW
			if(charBuffer == "E") begin
				EW	<= 1'b1;
			end
			else begin
				EW	<= 1'b0;
			end
		end
		
		//解析海拔
		if(cntField == 5'd9) begin
			if(cntChar == 4'd1) begin
				alt			<= num;
				afterDot	<= 1'b0;
			end
			else if(charBuffer==".") begin
				afterDot	<= 1'b1;
				alt2		<= 4'd0;
			end
			else begin
				if(~afterDot) begin
					alt		<= alt*4'd10 + num;		//alt-MMM
				end
				else begin
					alt2	<= alt2*4'd10 +num;		//alt-.M
				end
			end
		end
	end
end

endmodule
//END OF parseGGA.v FILE***************************************************


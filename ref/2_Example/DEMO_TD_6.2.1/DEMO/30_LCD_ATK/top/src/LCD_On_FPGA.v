module LCD_On_FPGA(clk,
						reset_n,
						tft_wrx,
						tft_rdx,
						tft_csx,
						tft_dcx,
						tft_reset_n,
						tft_d_inout,
						tft_bl,
                  SEL,
   	            DIG
);

	input clk,reset_n;
	output tft_wrx,tft_dcx,tft_rdx,tft_csx;
	output  tft_bl;
	inout[15:0]tft_d_inout;
	output reg tft_reset_n;
   output 		   [7:0]       	SEL;
   output 		   [7:0]     	DIG;
	
	
	
   `define     White     16'hFFFF
	`define     Black     16'h0000
	`define     Blue      16'h001F
	`define     Blue2     16'h051F
	`define     Red       16'hF800
	`define     Magenta   16'hF81F
	`define     Green     16'h07E0
	`define     Cyan      16'h7FFF
	`define     Yellow    16'hFFE0
	
	`define     IDLE    2'b00
	`define     DATA    2'b01
	`define     CMD     2'b10
	
	reg [2:0]  color_cnt;
	reg [7:0]  color_display_cnt;
	reg [15:0]  color_data;
	/*********************************************************************/
						
	wire write_done_sig;
	wire read_done_sig;
	reg[15:0]write_data;
	wire[15:0]read_data;
	reg[1:0]sig;//sig=2'b10传送的为地址命令 sig=2’b01传送为为数据
	reg wr_rd_sig;//wr_rd_sig=1 写 wr_rd_sig=0 读
	wire [15:0]write_d;
	wire [15:0]read_d;
	
	reg write_read_stop;
	reg start_init;
	reg read_ram_flag;
	

	
	write_read U1(
				.clk(clk),
				.rstn(reset_n),
				.wrx(tft_wrx),
				.rdx(tft_rdx),
				.csx(tft_csx),
				.dcx(tft_dcx),
				.write_d(write_d),
				.read_d(read_d),
				.write_done_sig(write_done_sig),
				.read_done_sig(read_done_sig),
				.write_data(write_data),
            .read_data(read_data),				
				.sig(sig),
				.wr_rd_sig(wr_rd_sig),
				.write_read_stop(write_read_stop)
				);
	

    seg seg1(
            .clk(clk),
            .seg_data(read_data),
            .DIG(DIG),
            .SEL(SEL)
    );




   picture_ram u2(
	               .clk(clk_r),
                  .i_we(picture_we),
                  .i_waddr(wr_addr),
						.i_raddr(rd_addr),
                  .i_wdata(picture_wr_data),
                  .o_rdata(picture_rd_data)
	
	);
 
	
	reg clk_r;
	reg[13:0]rd_addr;
	wire[15:0]picture_rd_data;
	reg[13:0]wr_addr;
	wire[15:0]picture_wr_data;
	wire picture_we;
	
	
	assign tft_bl = 1'b1;

	assign picture_we = 1'b0;
	assign tft_d_inout = wr_rd_sig ? write_d : 16'hzzzz;//wr_rd_sig控制三态门
	assign read_d =  tft_d_inout;
   
	
							
	/*********************************************************************/
	
//初始化硬件复位,从高拉低100ms后拉高
	
	reg[22:0]rst_cnt;
	parameter rst_t2ms = 23'd100000;              //2ms延时,2ns * 50*10^5 = 100ms 
	parameter rst_t100ms = 23'd5_000_000;              //20ms延时,2ns * 50*10^5 = 100ms  
	parameter rst_t150ms = 23'd7500000;              //150ms延时,2ns * 75*10^5 = 150ms  
	always@(posedge clk or negedge reset_n)
	begin
		if(!reset_n)begin
			rst_cnt <= 23'd0;
			tft_reset_n <= 1'b1;
			start_init <= 1'b0;
		end	
	   else if(rst_cnt == rst_t2ms)begin		
			tft_reset_n <= 1'b0;
			rst_cnt <= rst_cnt + 1'b1;
		end 	
		else if(rst_cnt == rst_t100ms)begin		
			tft_reset_n <= 1'b1;
			rst_cnt <= rst_cnt + 1'b1;
		end 
		else if(rst_cnt == rst_t150ms)begin
		   start_init <= 1'b1;
			rst_cnt <= rst_cnt;
		end	
		else
			rst_cnt <= rst_cnt + 1'b1;
	end
	
	

	
	
	parameter delay = 3'd5;              //100ns延时
					
	reg[2:0]cnt;
	reg start;
	always@(posedge clk or negedge reset_n)
	begin
		if(!reset_n)
			cnt <= 3'd0;
		else if((cnt == delay) || (start == 1'b0))
			cnt <= 3'd0;
		else if(start)
			cnt <= cnt + 1'b1;			
	end
			

	
	
	
	reg[22:0]cnt50;
	reg start_cnt50;
	parameter t50ms = 23'd2500000;              //50ms延时,2ns * 50*10^6 = 100ms  
	always@(posedge clk or negedge reset_n)
	begin
		if(!reset_n)begin
			cnt50 <= 23'd0;
		end	
		else if(cnt50 == t50ms)begin
			cnt50 <= cnt50;
		end
		else if(start_cnt50)
			cnt50 <= cnt50 + 1'b1;
	end
	
	
   reg[22:0]cnt120;
	reg start_cnt120;
	parameter t120ms = 23'd6000000;              //120ms延时,2ns * 50*10^6 = 100ms  
	always@(posedge clk or negedge reset_n)
	begin
		if(!reset_n)begin
			cnt120 <= 23'd0;
		end	
		else if(cnt120 == t120ms)begin
			cnt120 <= cnt120;
		end
		else if(start_cnt120)
			cnt120 <= cnt120 + 1'b1;
	end
	
	
	
	
	
	
	/*********************************************************************/
	reg[8:0]i;
	reg[16:0]st;//初始化显示
	reg[16:0]readcnt;//读显存数据计数
	
	
	/*****************************开窗数据**********************************/
   reg[16:0]sta;
	reg[15:0]x_r,y_r;//x列起始,y行起始	
	reg[16:0]pic_cnt; 

	
	parameter x = 16'd0;//列起始
	parameter y = 16'd0;//行
	parameter len = 16'd1;//列宽度
	parameter wid = 16'd1;//行宽度
	parameter pic_len = 16'd240;//显示图形的行宽度
	parameter pic_wid = 16'd320;//显示图形的列宽度
	parameter x_pic = (x + pic_len - 1'b1);        //显示图形的行末尾
	parameter y_pic = (y + pic_wid - 1'b1);        //显示图形的列末尾 
	parameter pixel_num = 17'h257f  ;  //像素点个数  9600-1
	parameter lcd_pixel_num = 17'h12c00  ;  //LCD像素点个数  76800
	
	
	
	/***********************初始化*****************************************/
	always@(posedge clk or negedge reset_n)
	if(!reset_n)
	begin 
		i <= 9'd0;
		sig <= `IDLE;
		start <= 1'b0;	
		write_read_stop<= 1'b1; //停止读写
		start_cnt50 <= 1'b0;	
	   start_cnt120 <= 1'b0;
	   st <= 17'd0;
		readcnt <= 17'd0;
	   read_ram_flag <= 1'b0;
		clk_r <= 1'b0;
		rd_addr <= 14'd0;
		wr_addr <= 14'd0;
		x_r <= x;
		y_r <= y;
		pic_cnt <= 17'd0;
	end
	else 
		case(i)
		
		0:if(write_done_sig)i <= i + 1'b1;//01
		else if(start_init)  begin start <= 1'b0;sig <= `CMD;write_data <= 16'h0001;wr_rd_sig <= 1'b1; write_read_stop<= 1'b0; end
		
		
		//把start_cnt50置1，开始50ms计时
		1:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start_cnt50 <= 1'b1; start <= 1'b1;end
		
		//delay 50 ms   
		2:if(cnt50 == t50ms) begin i <= 9'd13; start_cnt50 <= 1'b0; end//把start_cnt50 置0
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
			
		//CMD：CF  
		13:if(write_done_sig)i <= i + 1'b1;
		else  begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00CF; wr_rd_sig <= 1'b1; end
		
		14:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		15:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		16:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		17:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h00C9;end
		
		18:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		19:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0030;end
		
		20:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD：ED
		21:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00ED;end
		
		22:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		23:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0064;end
		
		24:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		25:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0003;end
		
		26:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		27:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0012;end
		
		28:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		29:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0081;end
		
		30:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD：E8
		31:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00E8;end
		
		32:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		33:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0085;end
		
		34:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		35:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0010;end
		
		36:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		37:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h007A;end
		
		38:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD：CB
		39:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00CB;end
		
		40:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		41:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0039;end
		
		42:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		43:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h002c;end
		
		44:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		45:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		46:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		47:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0034;end
		
		48:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		49:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0002;end
		
		50:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//CMD:F7
		51:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00F7;end
		
		52:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		53:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0020;end
		
		54:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:EA
		55:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00EA;end
		
		56:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		57:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		58:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		59:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		60:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:C0
		61:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00C0;end
		
		62:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		63:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h001b;end
		
		64:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:C1
		65:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00C1;end
			
		66:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		67:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		68:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:C5
		69:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00C5;end
		
		70:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		71:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0030;end
		
		72:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		73:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0030;end
		
		74:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:C7
		75:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00C7;end
		
		76:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		77:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h00B7;end
		
		78:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:36
		79:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h0036;end
		
		80:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		81:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0008;end
		
		82:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:3A
		83:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h003A;end
		
		84:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		85:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0055;end
		
		86:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD：B1
		87:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00B1;end
		
		88:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		89:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		90:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		91:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h001A;end
		
		92:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD：B6
		93:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00B6;end
		
		94:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		95:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h000A;end
		
		96:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		97:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h00A2;end
		
		98:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD：F2
		99:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00F2;end
		
		100:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		101:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		102:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:26
		103:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h0026;end
		
		//delay
		104:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:01
		105:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0001;end
		
		//delay
		106:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:E0
		107:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00E0;end
		
		//delay
		108:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:0f
		109:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h000F;end
		
		//delay
		110:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:2a
		111:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h002A;end
		
		//delay
		112:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:28
		113:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0028;end
		
		//delay
		114:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:08
		115:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0008;end
		
		//delay
		116:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:0e
		117:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h000E;end
		
		//delay
		118:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:08
		119:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0008;end
		
		//delay
		120:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:54
		121:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0054;end
		
		//delay
		122:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:a9
		123:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h00A9;end
		
		//delay
		124:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:43
		125:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0043;end
		
		//delay
		126:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:0a
		127:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h000A;end
		
		//delay
		128:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:0f
		129:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h000F;end
		
		//delay
		130:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:00
		131:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		
		//delay
		132:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:00
		133:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		//delay
		134:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:00
		135:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		//delay
		136:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:00
		137:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		//delay
		138:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:e1
		139:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00E1;end
		
		//delay
		140:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:00
		141:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		//delay
		142:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:15
		143:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0015;end
		
		//delay
		144:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:17
		145:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0017;end
		
		//delay
		146:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:07
		147:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0007;end
		
	   //delay
		148:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:11
		149:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0011;end
		
		//delay
		150:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:06
		151:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0006;end
		
		//delay
		152:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:2b
		153:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h002B;end
		
		//delay
		154:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:56
		155:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0056;end
		
		//delay
		156:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:3c
		157:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h003C;end
		
		//delay
		158:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:05
		159:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0005;end
		
		//delay
		160:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:10
		161:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0010;end
		
		//delay
		162:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:0f
		163:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h000F;end
		
		//delay
		164:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:3f
		165:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h003F;end
		
		//delay
		166:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:3f
		167:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h003F;end
		
		//delay
		168:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:0f
		169:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h000F;end
		
		//delay
		170:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:2b
		171:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h002B;end
		
		//delay
		172:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:00
		173:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		//delay
		174:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:00
		175:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		//delay
		176:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:01
		177:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0001;end
		
		//delay
		178:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:3f
		179:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h003f;end
		
		//delay
		180:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//CMD:2a
		181:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h002A;end
		
		//delay
		182:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:00
		183:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		//delay
		184:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:00
		185:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		//delay
		186:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:00
		187:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
		
		//delay
		188:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//data:ef
		189:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h00ef;end
	
		
		
		
		
		//delay
		190:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//sleep out
		//CMD:11
		191:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h0011;end
		
		
		//把start_cnt120置1，开始120ms计时
		192:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start_cnt120 <= 1'b1; start <= 1'b1;end
		
		//delay 120 ms   
		193:if(cnt120 == t120ms) begin i <= i + 1'b1; start_cnt120 <= 1'b0; end//把start_cnt120 置0
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:29
		194:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h0029;end
		
		
		/***********************初始化结束****************************/
		
	
	   /*******************开始设置LCD扫描方向****************************/
		
		
		
		//delay
		195:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//从左到右，从上到下
		//CMD:36
		196:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h0036;end
		
		//delay
		197:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:08
		198:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0008;end
		
		//设置模块列地址  起始：0 终止：239
	   //delay
		199:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:2a
		200:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h002A;end
		
	   
		//delay
		201:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:00 列起始高8位
		202:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
	
	   //delay
		203:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:00 列起始低8位
		204:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
	
	   //delay
		205:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:00 列终止高8位
		206:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
	
	    //delay
		207:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:239  ef 列终止低8位
		208:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h00ef;end
	
	   //设置模块行地址  起始：0 终止：319
	   //delay
		209:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:2b
		210:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h002B;end
		
	   
		//delay
		211:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:00 行起始高8位
		212:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
	
	   //delay
		213:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:00 行起始低8位
		214:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
	
	   //delay
		215:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:00 行终止高8位
		216:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0001;end
	
	    //delay
		217:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:13f  0x13f 列终止低8位
		//218:if(write_done_sig)i <= i + 1'b1;
		//else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h013f;end
	
	   //data:3f  0x3f 列终止低8位
		218:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h003f;end
	   
		//delay
		219:if(cnt == delay)i <= 9'd240;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
	
	   /*******************结束设置LCD扫描方向****************************/
		
		
		/*************************开始清屏****************************************/
		
		
	  
		
		
		
		//CMD:2c
		240:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h002C;end
		
		//delay
		241:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		
		//传送清屏数据
		242:if(st < 17'd76800)//送320*240次数据
			begin
				if(write_done_sig)begin
					i <= i + 1'b1;
				   st <= st + 1'b1;  
				end
				else 
				begin 
					sig <= `DATA;		
					start <= 1'b0;
					 if(st < 9600)  //240*40
						write_data <= `White;
					 else if(st < 9600*2)  //240*40
						write_data <= `Green;
					 else if(st < 9600*3)  //240*40
						write_data <= `Green;
					 else if(st < 9600*4)  //240*40
						write_data <= `Green;
					 else if(st < 9600*5)  //240*40
						write_data <= `Green;
					 else if(st < 9600*6)  //240*40
						write_data <= `Green;
					 else if(st < 9600*7)  //240*40
						write_data <= `Green;
					 else if(st < 9600*8)  //240*40
						write_data <= `Green;
					
				end
			end
			else 
				i <= 244;     //完成所有数据传输

		243:if(cnt == delay)
				i <= 242;
			else 
			begin 
				i <= i;
				sig <= `IDLE;
				start <= 1'b1;
			end
		
		
		//开启模块显示
		//delay
		244:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:29
		245:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h0029;end
			
		//delay
		246:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;  end
			
		//247: begin i <= i; write_read_stop <= 1'b1;end
		
		
		
	
		
		/*************************结束清屏****************************************/
		
		
		/*************************开始显示图片****************************************/
		
		
		
		247: begin clk_r <= 1'b0;i <= i + 1'b1;start <= 1'b0;end
		
		248:begin clk_r <= 1'b1;i <= i + 1'b1;end
		
		
		//CMD:2A
		249:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h002a;end//行范围
		
		250:if(cnt == delay)i <=  i + 1'b1;
		else begin i <=  i;sig <= `IDLE;start <= 1'b1;end
		
		251:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= (x_r>>8);end//行起始高8位
		
		252:if(cnt == delay)i <=  i + 1'b1;
		else begin i <=  i ;sig <= `IDLE;start <= 1'b1;end
		
		253:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= (x_r-((x_r>>8)<<8));end//行起始低8位	
		
		254:if(cnt == delay)i <=  i + 1'b1;
		else begin i <=  i ;sig <= `IDLE;start <= 1'b1;end
		
		255:if(write_done_sig)i <=  i + 1'b1;	
		else begin start <= 1'b0;sig <= `DATA;write_data <= ((x_r+len-1)>>8);end//行终止高8位
		
		256:if(cnt == delay)i <=  i + 1'b1;
		else begin i <=  i ;sig <= `IDLE;start <= 1'b1;end
		
		257:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= ((x_r+len-1)-(((x_r+len-1)>>8)<<8));end//行终止低8位
		
		258:if(cnt == delay)i <=  i + 1'b1;
		else begin i <=  i ;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:2b
		259:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h002b;end//行范围
		
		260:if(cnt == delay)i <=  i + 1'b1;
		else begin i <=  i ;sig <= `IDLE;start <= 1'b1;end
		
		261:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= (y_r>>8);end//行起始高8位
		
		262:if(cnt == delay)i <=  i + 1'b1;
		else begin i <=  i ;sig <= `IDLE;start <= 1'b1;end
		
		263:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= (y_r-((y_r>>8)<<8));end//行起始低8位
		
		264:if(cnt == delay)i <=  i + 1'b1;
		else begin i <=  i ;sig <= `IDLE;start <= 1'b1;end
		
		265:if(write_done_sig)i <=  i + 1'b1;	
		else begin start <= 1'b0;sig <= `DATA;write_data <= ((y_r+wid-1)>>8);end//行终止高8位
		
		266:if(cnt == delay)i <=  i + 1'b1;
		else begin i <=  i ;sig <= `IDLE;start <= 1'b1;end
		
		267:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= ((y_r+wid-1)-(((y_r+wid-1)>>8)<<8));end//行终止低8位
		
		268:if(cnt == delay)i <=  i + 1'b1;
		else begin i <=  i ;sig <= `IDLE;start <= 1'b1;end
		
      //CMD:2c		
		269:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h002c;end
		
		270:if(cnt == delay)i <=  i + 1'b1;
		else begin i <=  i ;sig <= `IDLE;start <= 1'b1;end
		
		271:if(write_done_sig)i <=  i + 1'b1;
			else begin start <= 1'b0;sig <= `DATA;write_data <= picture_rd_data;end//5:6:5 RGB 颜色数据
			
		272:if(cnt == delay)i <=  i + 1'b1;
		else begin i <=  i ;sig <= `IDLE;start <= 1'b1;end
		
		
		273:if(x_r < x_pic)begin x_r <= x_r + 1'b1;y_r <= y_r;i <= i + 1'b1;end
			else if(x_r == x_pic && y_r < y_pic)begin x_r <= x;y_r <= y_r + 1'b1;i <= i + 1'b1;end
			else i <= 275;
			
		274:if(rd_addr < pixel_num)                   //9600 -1
		begin i <= 247;rd_addr <= rd_addr + 1'b1;pic_cnt <= pic_cnt + 1'b1; end
		else if((rd_addr == pixel_num) &&  pic_cnt < lcd_pixel_num ) begin rd_addr <= 14'd0;pic_cnt <= pic_cnt + 1'b1;end
		else i <= i + 1'b1;
		
		275:begin i <= i; write_read_stop <= 1'b1;end
		
		
		
		
		
		/*************************结束显示图片****************************************/
		
		
		
		
		
		/*
		
		//读LCD状态
		
		//CMD:09
		248:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h0009;end
		
		//delay
		249:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;  end
		
		//read data1
		250:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		251:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//read data2
		252:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		253:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//read data3
		254:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		255:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//read data4
		256:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		257:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//read data5
		258:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		259:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		
		//读power
		//delay
		260:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1; wr_rd_sig <= 1'b1; end
		
		//CMD:0a
		261:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h000a;end
		
		//delay
		262:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;  end
		
		//read data1
		263:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		//delay
		264:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;  end
		
		//read data2
		265:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		
		//读显示方向
		//delay
		266:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1; wr_rd_sig <= 1'b1; end
		
		//CMD:0b
		267:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h000b;end
		
		//delay
		268:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;  end
		
		//read data1
		269:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		//delay
		270:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;  end
		
		//read data2
		271:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		
		//读显示像素格式
		//delay
		272:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1; wr_rd_sig <= 1'b1; end
		
		//CMD:0c
		273:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h000c;end
		
		//delay
		274:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;  end
		
		//read data1
		275:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		//delay
		276:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;  end
		
		//read data2
		277:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		//delay
		278:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;  end
		
		
		//读一次ID
		//CMD:d3
		279:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h00d3;wr_rd_sig <= 1'b1;end
		
		//delay
		280:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;  end
		
		//read data1
		281:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		282:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//read data2
		283:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		284:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//read data3
		285:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		286:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//read data4
		287:if(read_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA; wr_rd_sig <= 1'b0; end
		
		288:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//end
		289:begin i <= i; write_read_stop <= 1'b1;  end
		
		
		
		//end
		//279:begin i <= i; write_read_stop <= 1'b1;  end
		
		
		
		
		
		
		
		/***********************读显存数据开始*******************************/
		
		
		
		/*
		
		//delay
		248:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;  end
		
		
		//设定读数据范围
		//设置模块列地址  起始：0 终止：240
		
		//CMD:2a
		249:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h002a;end
		
	   
		//delay
		250:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:00 列起始高8位
		251:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
	
	   //delay
		252:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:00 列起始低8位
		253:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
	
	   //delay
		254:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:00 列终止高8位
		255:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
	
	    //delay
		256:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:240  f0 列终止低8位
		257:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h00f0;end
	
	   //设置模块行地址  起始：0 终止：320
	   //delay
		258:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//CMD:2b
		259:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h002b;end
		
	   
		//delay
		260:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:00 行起始高8位
		261:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
	
	   //delay
		262:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:00 行起始低8位
		263:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
	
	   //delay
		264:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:00 行终止高8位
		265:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0000;end
	
	    //delay
		266:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
		//data:320  0x140 列终止低8位
		267:if(write_done_sig)i <= i + 1'b1;
		else begin start <= 1'b0;sig <= `DATA;write_data <= 16'h0140;end
		
		
		 //delay
		268:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		
	
	    //开始读数据
	   //CMD:2e
		269:if(write_done_sig)i <=  i + 1'b1;
		else begin start <= 1'b0;sig <= `CMD;write_data <= 16'h002e; read_ram_flag <= 1'b1;  end
	
	   //delay
		270:if(cnt == delay)i <= i + 1'b1;
		else begin i <= i;sig <= `IDLE;start <= 1'b1;end
		
		//循环读数据
		271:if(readcnt < 17'd76800)//读240*320次数据
			begin
				if(read_done_sig)begin
					i <= i + 1'b1;
					readcnt <= readcnt + 1'b1;   
				end	
				else 
				begin 
					sig <= `DATA;
					wr_rd_sig <= 1'b0;
					start <= 1'b0;
				end
			end
			else 
				i <= 273;     //完成所有数据读取

		272:if(cnt == delay)
				i <= 271;
			else 
			begin 
				i <= i;
				sig <= `IDLE;
				start <= 1'b1;
			end
		
		
		273:i <= i +1'b1;
		
		
		//end
		274:begin i <= i; write_read_stop <= 1'b1;  end
		
		*/
		
		
	
		
		
		
		
		
		
		/***********************读显存数据结束*******************************/
		
		
		
		
		
		
		
		
	endcase
	
	



	/*****************************************************************/ 

						
						



endmodule

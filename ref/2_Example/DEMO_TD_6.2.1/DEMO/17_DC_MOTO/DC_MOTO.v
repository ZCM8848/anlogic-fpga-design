// Create Date: 2021/03/15 10:20:41
// Design Name: 直流电机测速
// Module Name: DC_MOTO
module DC_MOTO( input clk50mhz,input k8, input cntn,input sl,
     output m0,output m1,output [6:0] data,output [7:0] spd
    );

   wire [7:0] cin;
   wire [7:0] adr;
   wire ot;
   wire clk1MHz;
   wire clk4KHz;
   wire  clk8Hz;
   wire  cnt_en;
   wire  clr_n;
   wire lock;
   wire kout;
   wire [7:0] qout;
   wire cout;
   clkdiv clkdiv_inst(.clkin(clk50mhz),.clk1MHz(clk1MHz),.clk4KHz(clk4KHz),.clk8Hz(clk8Hz)); //时钟分频
   ERZP  ERZP_inst(.CLK(clk1MHz),.KIN(~cntn),.KOUT(kout)); //光感消抖动
   FREQTEST FREQTEST_inst(.clk(clk8Hz),.FSIN(FSIN),.cout(CCOUT),.dout(spd));//1hz门控信号
  // TESTCTL TESTCTL_inst(.CLK(clk8Hz),.TSTEN(cnt_en),.CLR_CNT(clr_n),.Load(lock));//1hz门控信号
 //  CNT10D CNT10D_inst(.clk(kout),.rst(clr_n) ,.en(cnt_en),.q(qout),.cout(cout) ); //速度计数
 //  REG8B REG8B_inst(.Load(lock),.DIN(qout),.DOUT(spd)); //速度显示
    CNT4  CNT4_inst(.CLK(k8),.Q(cin[7:4])); //调速模块
    CNT8 CNT8_inst(.CLK(clk4KHz),.Q(adr));  //计数器
    SQU1 SQU1_inst(.CIN(cin),.ADR(adr), .OT(ot)); 
    SLT SLT_inst(.SL(sl), .M(~ot), .M0(m0), .M1(m1)); //电机正反转选择
    assign  data = cin[7:4];
    assign  cin[3:0] = 4'b0000; 
endmodule

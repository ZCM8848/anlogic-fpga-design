// Create Date: 2021/03/08 15:15:25
// Design Name: 梁祝乐曲播放器
// Module Name: SONG
module SONG( input clk50mhz,output [3:0] LED,
       output high,output spk,input rst
);
wire clk1mhz;    //音乐音色时钟
wire clk4hz;    //音乐节拍信号
wire [7:0] adder; //8位地址
wire [3:0] inx;  //乐谱数据
wire spks;
wire [10:0] tone; //分频预置数
wire  q1;
clk_divide u1(.clk(clk50mhz),.rst(~rst),.c0(clk1mhz),.c1(clk4hz));
CNT138T u2(.CLK(clk4hz), .CNT8(adder));
blk_mem_gen_0 u3 (
  .clka(clk4hz),    // input wire clka
  .addra(adder),  // input wire [7 : 0] addra
  .doa(inx)  // output wire [3 : 0] douta
);


F_CODE u4(.INX(inx),.CODE(LED),.H(high),.TO(tone));
SPKER u5(.CLK(clk1mhz), .TN(tone),.SPKS(spks));
DFF u6(
	.CLK(spks),
	.D(~q1),
	.Q(q1)
);
assign   spk=q1;  
endmodule

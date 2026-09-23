// Create Date: 2021/03/16 12:33:18
// Design Name: 8位十进制计数器
// Module Name: CNT10D
module CNT10D( input clk,input rst ,input en,output [7:0] q,
    output cout
    );
    wire ck1;
    CNT10 u1(.clk(clk),.rst(rst),.en(en),.count(ck1),.dout(q[3:0]) );
    CNT10 u2(.clk(ck1),.rst(rst),.en(en),.count(cout),.dout(q[7:4]) );
endmodule

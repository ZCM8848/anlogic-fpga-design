// Create Date: 2021/03/18 13:52:06
// Design Name: 地址计数器
// Module Name: count9b
module count9b( input clk, output reg [8:0] q

    );
    always@(posedge clk)
     q = q + 1;
endmodule

// Create Date: 2021/03/18 16:40:29
// Design Name: 系统时钟分频为1MHz
// Module Name: clk_div
module clk_div( input clk,output reg clk1mhz

    );
     reg [4:0] cnt;
     always@(posedge clk)
      if(cnt==5'd24)
      begin clk1mhz <= ~clk1mhz;
            cnt <= 5'd0;end
            else cnt <= cnt + 1;
           
endmodule

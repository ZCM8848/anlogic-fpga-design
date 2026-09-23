module clk_divide(
                input clk,
                input rst,
                output reg c0,
                output reg c1
    );
parameter c0_div = 6'D50;   //1MHz
parameter c1_div = 24'D12_500_000; //4Hz
reg[5:0] c0_cnt;
reg[23:0]  c1_cnt;
    
always@(posedge clk or posedge rst) begin
        if(rst)
            begin c0<=0;  c0_cnt<=0;  end
        else if(c0_cnt >= c0_div/2-1)
            begin c0_cnt <= 0; c0 <= ~c0;  end
        else 
            c0_cnt = c0_cnt + 1;
end


always@(posedge clk or posedge rst)begin
        if(rst)
            begin c1<=0; c1_cnt<=0;  end
        else if(c1_cnt >= c1_div/2-1)
            begin c1_cnt <= 0; c1 <= ~c1; end
        else 
            c1_cnt = c1_cnt + 1;
        end
endmodule
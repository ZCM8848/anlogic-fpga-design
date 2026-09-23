module addr_crt (
 input         clk,
 input         rst_n,
 input   [7:0] udp_data,
 input         udp_vaild,
 input   [15:0]udp_length,
 
 output reg [15:0] wr_addr,
 output        wr_en,
 output        rd_en,
 output reg [7:0] ram_data,
 reg [7:0]   udp_data_app
);


reg         length;
reg         cnt_vaild;
reg          cnt  ;
reg  [9:0]   cnt_h;
reg  [9:0]   cnt_v;
reg  [3:0]   cnt_length;
reg          done;
//reg          addr_vaild;
reg          vaild1;
reg          skip_en;
reg          error_en;
reg          finish;

parameter IDLE  = 3'b000 ;
parameter S_CHECK =3'b001;
parameter S_ADDR =3'b010 ;
parameter S_LENG =3'b011 ;
parameter S_DATA =3'b100 ;
parameter S_FINISH=3'b101;
parameter S_OVER =3'b110;
parameter N      =3'b001;
wire posedge_vaild;
assign wr_en=!done;
assign rd_en=done;

reg [3:0]state,state_next;

always@(posedge clk or negedge rst_n)
begin 
    if(~rst_n)
    state <= 3'h0;
    else
    state <= state_next;
end
assign posedge_vaild = udp_vaild?~vaild1:0;
always @(*)
begin
    state_next=IDLE;
    case(state)
        IDLE  : if (posedge_vaild==1) 
                    state_next=S_CHECK;
                else
                    state_next=IDLE; 
        S_CHECK:if(skip_en)
                    state_next=S_ADDR;
                else
                    state_next=IDLE;
        S_ADDR: if(skip_en)
                    state_next=S_LENG; 
                else 
                     state_next=S_ADDR;
        S_LENG: if (skip_en)
                    state_next=S_DATA;
                else
                    state_next=IDLE;
        S_DATA: if (finish)
                    state_next=S_FINISH;
                else if(skip_en)
                    state_next=IDLE;
                else state_next=S_DATA;
        S_FINISH:if(skip_en)
                    state_next=S_OVER;
                else//error_en用做代表连续次数据包复写完毕
                    state_next=IDLE;
        S_OVER: state_next=S_OVER;
    endcase
end
reg cnt_finish;
reg [15:0]   wr_addr_length;
always@(posedge clk or negedge rst_n)begin 
    if(~rst_n) begin
    skip_en<= 1'b0;
    error_en<=1'b0;
    cnt     <=1'b0;
    cnt_finish<=0;
    finish  <=1'b0;
    done    <=1'b0;
    wr_addr <=0;
    ram_data<=0;
    end
    else begin
    skip_en<= 1'b0;
    error_en<=1'b0;
    finish <=1'b0;
    case (state_next)
        IDLE: begin
            wr_addr<=wr_addr;
            ram_data<=ram_data;
        end
        S_CHECK:begin
            skip_en<=(udp_data==8'b00001111)?1:0;
        end
        S_ADDR:begin
            cnt<=cnt+1;
            if(cnt==0)
            wr_addr<={udp_data,wr_addr[7:0]};
            else if (cnt==1)begin
            wr_addr<={wr_addr[15:8],udp_data};
            skip_en<=1;
            cnt<=0;
        end
        end
        S_LENG:begin
            length<=udp_data;
            wr_addr_length<=wr_addr+udp_data-1;
            skip_en<=1;
        end
        S_DATA:begin
            wr_addr<=wr_addr+1;
            if(wr_addr<wr_addr_length)
            ram_data<=udp_data;
            else if (wr_addr==wr_addr_length)begin
                if (wr_addr<'d255)begin
                ram_data<=udp_data;
                skip_en<=1;
                end
                else
                finish<=1;
            end
        end
        S_FINISH:begin
            cnt_finish<=cnt_finish+1;
            if (cnt_finish<1)
            skip_en<=0;
            else if (cnt_finish == 1)
            skip_en<=1;
        end
        S_OVER:begin
            done<=1'b1;
        end
            

            
    endcase
    end
end

always @(posedge clk or negedge rst_n ) begin
    if(!rst_n)begin
    vaild1<=0;
    cnt_vaild<=0;
    end
    else begin
    vaild1<=udp_vaild;
    cnt_vaild<=vaild1;
    end       
end
always @(posedge clk or negedge rst_n ) begin
    if(!rst_n)begin
    udp_data_app<=0;
    end
    else begin
    udp_data_app<=udp_data;
    end       
end
endmodule



//记length个有效时钟
/*always @(posedge clk or negedge rst_n ) begin
    if(!rst_n)
        cnt_length;
    else if (cnt_vaild==1)
        cnt_length<=cnt_length+1;
    else if (0<cnt_length<udp_length-1)
        cnt_length<=cnt_length+1;
    else if (cnt_length==udp_length-1)
        cnt_length<=0;
    else
        cnt_length<=cnt_length;    
end*/

//列计数器
/*always @(posedge clk or negedge rst_n ) begin
    if(!rst_n)
    cnt_h<=0;
    else if (cnt_vaild==1)begin
            if (cnt_h<10'd639)
            cnt_h<=cnt_h+1;
            else if (cnt_h==10'd639)
            cnt_h<=0;
    end
end

//行计数器
always @(posedge clk or negedge rst_n ) begin
    if(!rst_n)
    cnt_v<=0;
    else if (cnt_h<10'd639)
            cnt_v<=cnt_v;
    else if (cnt_h==10'd639)
            cnt_v<=cnt_v+1;
    else if (cnt_h==10'd639 & cnt_v==10'd479 )begin
            cnt_v<=0;
    end
end

//ram地址生成
always @(posedge clk or negedge rst_n ) begin
    if(!rst_n)begin
    wr_addr<=0;
    done<=0;
    end
    else if (cnt_vaild==1)begin
            if (cnt_h<10'd255 & cnt_v<10'd127)
            wr_addr<=wr_addr+1;
            else if (cnt_h==10'd255 & cnt_v==10'd127)begin
            wr_addr<=0;
            done<=1;
            end
    else wr_addr<=wr_addr;
    end
end*/
    

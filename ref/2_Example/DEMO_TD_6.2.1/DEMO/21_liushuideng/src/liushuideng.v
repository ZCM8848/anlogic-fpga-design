module  liushuideng(

input                       sclk            ,
input                       rst_n           ,
output  reg     [11:0]       led 

);

reg         [25:0]              cnt             ;

parameter   max         =       9_999_999      ;

always@(posedge sclk or negedge rst_n)
if(!rst_n)
    cnt         <=              0               ;
else if(cnt==max)
    cnt         <=              0               ;
else
    cnt         <=              cnt+1'b1        ;   

reg                             flag            ;

always@(posedge sclk or negedge rst_n)
if(!rst_n)
    flag        <=              0               ;
else if(led==12'b011111111111)
    flag        <=              1               ;
else if(led==12'b111111111110)
    flag        <=              0               ;   

always@(posedge sclk or negedge rst_n)
if(!rst_n)
    led         <=              12'b111111111110  ;
else if(cnt==max&&flag==0)
    led         <=          {led[10:0],led[11]}   ;
else if(cnt==max&&flag==1)
    led         <=          {led[0],led[11:1]}   ;

endmodule 
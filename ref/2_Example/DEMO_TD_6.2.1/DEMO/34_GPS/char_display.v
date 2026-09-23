

module char_display(
    input                               clk                        ,
    input                               rst_n                      ,
    

    output             [  11: 0]        video_data                 ,//RGB444颜色数据
    
    input              [  10: 0]        pixel_xpos                 ,//像素点横坐标
    input              [  10: 0]        pixel_ypos                 ,//像素点纵坐标
    input                               data_req                   ,
    input              [   4: 0]        hh                         ,
    input              [   5: 0]        mm                         ,
    input              [   5: 0]        ss                         ,
    input              [   6: 0]        ss2                        ,
    input              [   6: 0]        lat                        ,
    input              [   5: 0]        lat2                       ,
    input              [  16: 0]        lat3                       ,
    input                               NS                         ,
    input              [   7: 0]        lon                        ,
    input              [   5: 0]        lon2                       ,
    input              [  16: 0]        lon3                       ,
    input                               EW                         ,
    input              [  13: 0]        alt                        ,
    input              [   3: 0]        alt2                        
);

//parameter define

//640*480 分辨率时序参数,60fps


wire [4:0] x_pos ;
wire [4:0] y_pos ;
wire [4:0] x_cnt ;
wire [14:0] y_cnt ;
wire [9:0] char_choose;
reg [4:0] char_choose_case;
//字符显示分区

wire [15:0] video_data_q;
assign x_pos = pixel_xpos >> 'd5  ;
assign y_pos = pixel_ypos >> 'd5  ;
assign x_cnt = pixel_xpos - (x_pos <<'d5)  ;
assign y_cnt = pixel_ypos - (y_pos <<'d5)  ;

     wire               [  15: 0]        rom_addr                   ;
assign video_data ={video_data_q[15:12],video_data_q[10:7],video_data_q[5:1]};

gps_char_rom u_gps_char_rom (
  .addra(rom_addr  ),                  // input [14:0]
  .clka(clk),                    // input
  .rsta(rsta),                    // input
  .ocea(data_req ),    // input
  .doa(video_data_q)             // output [15:0]
);



// reg [9:0] addr_cnt;
    // always @(posedge clk or negedge rst_n)           
    //     begin                                        
    //         if(!rst_n)                               
    //         addr_cnt <='b0;                                       
    //         else if(data_req  && addr_cnt <'d703)                                
    //         addr_cnt <= addr_cnt+'b1     ;                                    
    //         else if(data_req  && addr_cnt =='d703)
    //         addr_cnt<='b0;
    //     end                                                                                 

assign     char_choose =  {y_pos, x_pos}   ;                               
//  assign     rom_addr =     data_req ?((y_cnt << 'd9) + (y_cnt << 'd7) + (y_cnt << 'd6) + addr_cnt ): 'b0;                                                        

assign     rom_addr =     data_req ? ((char_choose_case == 'd22) ?'b0 :(y_cnt << 'd9) + (y_cnt << 'd7) + (y_cnt << 'd6) + (char_choose_case << 'd5) + x_cnt ): 'b0;  
// assign     rom_addr =     ({y_pos, x_pos} == 'b0000000000) ?(y_cnt << 'd9) + (y_cnt << 'd7) + (y_cnt << 'd6) + x_cnt : 'b0;  
    always @(posedge clk or negedge rst_n)           
        begin                                        
            if(!rst_n)                               
            char_choose_case<='b0;                                       
            else                                
            case (char_choose)
            'b0000000000:
                char_choose_case<='d10;
            'b0000000001:
                char_choose_case<='d11;
            'b0000000010:
                char_choose_case<= hh / 'd10 ;
            'b0000000011:
                char_choose_case<= hh % 'd10;
            'b0000000100:
                char_choose_case<='d21;
            'b0000000101:
                char_choose_case<=mm / 'd10;
            'b0000000110:
                char_choose_case<=mm % 'd10;
            'b0000000111:
                char_choose_case<='d21;
            'b0000001000:
                char_choose_case<=ss / 'd10;
            'b0000001001:
                char_choose_case<=ss % 'd10;
            'b0000001010:    
                char_choose_case<='d21;
            'b0000001011:
                char_choose_case<=ss2 / 'd10;
            'b0000001100:
                char_choose_case<=ss2 % 'd10;
            'b0000100000:
                char_choose_case<='d12;
            'b0000100001:
                char_choose_case<='d13;
            'b0000100010:
                char_choose_case<= lat / 'd10 ;
            'b0000100011:
                char_choose_case<= lat % 'd10;
            'b0000100100:    
                char_choose_case<='d21;
            'b0000100101:
                char_choose_case<=lat2 / 'd10;
            'b0000100110:
                char_choose_case<= lat2 % 'd10;
            'b0000100111:    
                char_choose_case<='d21;
            'b0000101000:
                char_choose_case<=(lat3 >>'d10) / 'd10;
            'b0000101001:
                char_choose_case<=(lat3 >>'d10) % 'd10;
            'b0001000000:
                char_choose_case<='d15;
            'b0001000001:
                char_choose_case<='d16;
            'b0001000010:
                char_choose_case<= NS ?  'd15 : 'd16;
            'b0001100000:
                char_choose_case<='d14;
            'b0001100001:
                char_choose_case<='d13;
            'b0001100010:
                char_choose_case<= lon / 'd100 ;
            'b0001100011:
                char_choose_case<= lon % 'd100  / 'd10;
            'b0001100100:    
                char_choose_case<= lon % 'd10;
            'b0001100101:
                char_choose_case<=lon2 / 'd10;
            'b0001100110:
                char_choose_case<=lon2 % 'd10;
            'b0001100111:    
                char_choose_case<='d21;
            'b0001101000:
                char_choose_case<=(lon3 >>'d10) / 'd10;
            'b0001101001:
                char_choose_case<=(lon3 >>'d10) % 'd10;
            'b0010000000:
                char_choose_case<='d17;
            'b0010000001:
                char_choose_case<='d18;
            'b0010000010:
                char_choose_case<= EW ?  'd17 : 'd18;
            'b0010100000:
                char_choose_case<='d19;
            'b0010100001:
                char_choose_case<='d20;
            'b0010100010:
                char_choose_case<= (alt >> 'd10) / 'd10 ;
            'b0010100011:
                char_choose_case<= (alt >> 'd10) % 'd10;
            'b0010100100:    
                char_choose_case<=alt % 'd1000/'d100;
            'b0010100101:    
                char_choose_case<=alt % 'd100 / 'd10;
            'b0010100110:    
                char_choose_case<=alt % 'd10;
            'b0010100111:    
                char_choose_case<='d21;
            'b0010101000:
                char_choose_case<=alt2 / 'd10;
                default:
                char_choose_case<='d22;
                // char_choose_case<='d0;  
            endcase                                    
        end      

                                        
endmodule
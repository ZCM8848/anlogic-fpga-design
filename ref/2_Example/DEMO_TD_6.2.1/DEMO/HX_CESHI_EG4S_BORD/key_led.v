module key_lcd(
    input               sys_clk  ,    //50Mhzϵͳʱ��
    input               sys_rst_n,    //ϵͳ��λ������Ч
    input        [7:0]  key,          //���������ź�
    output  reg  [3:0]  lcd           //lcd�����ź�

    );

//reg define     
reg  [23:0] cnt;
reg  [1:0]  lcd_control;

//���ڼ���0.2s�ļ�����
always @ (posedge sys_clk or negedge sys_rst_n) begin
    if(!sys_rst_n)
        cnt <= 24'd0;         
    else if(cnt < 24'd9_999_999)
    //else if(cnt < 24'd9)       //�����ڷ���
        cnt<=cnt+1;
    else
        cnt<=0;
end 

//����lcd��״̬��ѡ��
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        lcd_control <= 2'b00;
    else if(cnt == 24'd9_999_999)
    //else if(cnt == 24'd9)            //�����ڷ���
        lcd_control <= lcd_control + 1'b1;
    else
        lcd_control <= lcd_control;
end

//ʶ�𰴼����л���ʾģʽ
always @(posedge sys_clk or negedge sys_rst_n) begin
    if(!sys_rst_n) begin
          lcd<=4'b0000;
    end
    else if(key[0]== 0)  //����1����ʱ��������������ˮ��Ч��
        case (lcd_control)
            2'b00   : lcd<=4'b1000;
            2'b01   : lcd<=4'b0100;
            2'b10   : lcd<=4'b0010;
            2'b11   : lcd<=4'b0001;
            default  : lcd<=4'b0000;
        endcase
    else if (key[1]==0)  //����2����ʱ���������ҵ���ˮ��Ч��
        case (lcd_control)
            2'b00   : lcd<=4'b0001;
            2'b01   : lcd<=4'b0010;
            2'b10   : lcd<=4'b0100;
            2'b11   : lcd<=4'b1000;
            default  : lcd<=4'b0000;
        endcase
    else if (key[2]==0)  //����3����ʱ��lcd��˸
        case (lcd_control)
            2'b00   : lcd<=4'b1111;
            2'b01   : lcd<=4'b0000;
            2'b10   : lcd<=4'b1111;
            2'b11   : lcd<=4'b0000;
            default  : lcd<=4'b0000;
        endcase
    else if (key[3]==0)  //����4����ʱ��lcdȫ��
        case (lcd_control)
            2'b00   : lcd<=4'b1111;
            2'b01   : lcd<=4'b1111;
            2'b10   : lcd<=4'b1111;
            2'b11   : lcd<=4'b1111;
            default  : lcd<=4'b0000;
        endcase
    else if(key[4]== 0)  //����1����ʱ��������������ˮ��Ч��
        case (lcd_control)
            2'b00   : lcd<=4'b1000;
            2'b01   : lcd<=4'b0100;
            2'b10   : lcd<=4'b0010;
            2'b11   : lcd<=4'b0001;
            default  : lcd<=4'b0000;
        endcase
    else if (key[5]==0)  //����2����ʱ���������ҵ���ˮ��Ч��
        case (lcd_control)
            2'b00   : lcd<=4'b0001;
            2'b01   : lcd<=4'b0010;
            2'b10   : lcd<=4'b0100;
            2'b11   : lcd<=4'b1000;
            default  : lcd<=4'b0000;
        endcase
    else if (key[6]==0)  //����3����ʱ��lcd��˸
        case (lcd_control)
            2'b00   : lcd<=4'b1111;
            2'b01   : lcd<=4'b0000;
            2'b10   : lcd<=4'b1111;
            2'b11   : lcd<=4'b0000;
            default  : lcd<=4'b0000;
        endcase
    else if (key[7]==0)  //����4����ʱ��lcdȫ��
        lcd<=4'b1111;
    else
        lcd<=4'b0000;    //�ް�������ʱ��lcdϨ��     





end
  





endmodule 
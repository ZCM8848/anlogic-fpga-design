
module video_driver(
    input                               pixel_clk                  ,
    input                               sys_rst_n                  ,
    //RGB�ӿ�
    output                              video_hs                   ,//��ͬ���ź�
    output                              video_vs                   ,//��ͬ���ź�
    output                              video_de                   ,//����ʹ��
    output             [  11: 0]        video_rgb                  ,//RGB888��ɫ����
    input              [  11: 0]        pixel_data                 ,//���ص�����
    output             [  10: 0]        pixel_xpos                 ,//���ص�������
    output             [  10: 0]        pixel_ypos                 ,//���ص�������
    output             [  10: 0]        h_disp                     ,//���ص�������
    output             [  10: 0]        v_disp                     ,//���ص�������   
    output                              data_req                    
);

//parameter define

//640*480 �ֱ���ʱ������,60fps
parameter  H_SYNC   =  11'd96;  //��ͬ��
parameter  H_BACK   =  11'd40;  //����ʾ����
parameter  H_DISP   =  11'd640; //����Ч����
parameter  H_FRONT  =  11'd8;   //����ʾǰ��
parameter  H_TOP  =  11'd8;   //����ʾtop
parameter  H_BOTTOM  =  11'd8;   //����ʾbottom
parameter  H_TOTAL  =  11'd800; //��ɨ������

parameter                V_SYNC            = 11'd2 ;    //��ͬ��
parameter                V_BACK            = 11'd25;   //����ʾ����
parameter                V_DISP            = 11'd480;  //����Ч����
parameter                V_FRONT           = 11'd2 ;    //����ʾǰ��
parameter                V_TOP             = 11'd8 ;    //����ʾǰ��
parameter                V_BOTTOM          = 11'd8 ;    //����ʾǰ��
parameter                V_TOTAL           = 11'd525;  //��ɨ������

//reg define
reg  [10:0]  cnt_h;
reg  [10:0]  cnt_v;

//wire define
wire        video_en;


//*****************************************************
//**                    main code
//*****************************************************

assign video_de  = video_en;

assign video_hs  = ( cnt_h < H_SYNC ) ? 1'b0 : 1'b1;  //��ͬ���źŸ�ֵ
assign video_vs  = ( cnt_v < V_SYNC ) ? 1'b0 : 1'b1;  //��ͬ���źŸ�ֵ

//ʹ��RGB��������
assign video_en  = (((cnt_h >= H_SYNC+H_BACK +H_TOP ) && (cnt_h < H_SYNC+H_BACK+H_DISP +H_TOP ))
                 &&((cnt_v >= V_SYNC+V_BACK +V_TOP ) && (cnt_v < V_SYNC+V_BACK+V_DISP +V_TOP )))
                 ?  1'b1 : 1'b0;

//RGB888��������
assign video_rgb = video_en ? pixel_data : 12'd0;
// assign video_rgb = video_en ? 'hfff : 12'd0;
//�������ص���ɫ��������
assign data_req = (((cnt_h >= H_SYNC+H_BACK+H_TOP-3'b1) && 
                    (cnt_h < H_SYNC+H_BACK+H_DISP +H_TOP -3'b1))
                  && ((cnt_v >= V_SYNC+V_BACK + V_TOP) && (cnt_v < V_SYNC+V_BACK+V_DISP + V_TOP)))
                  ?  1'b1 : 1'b0;

//���ص�����
assign pixel_xpos = data_req ? (cnt_h - (H_SYNC + H_BACK +H_TOP - 1'b1)) : 11'd0;
assign pixel_ypos = data_req ? (cnt_v - (V_SYNC + V_BACK + V_TOP - 1'b1)) : 11'd0;

//�г��ֱ���
assign h_disp = H_DISP;
assign v_disp = V_DISP; 

//�м�����������ʱ�Ӽ���
always @(posedge pixel_clk ) begin
    if (!sys_rst_n)
        cnt_h <= 11'd0;
    else begin
        if(cnt_h < H_TOTAL - 1'b1)
            cnt_h <= cnt_h + 1'b1;
        else 
            cnt_h <= 11'd0;
    end
end

//�����������м���
always @(posedge pixel_clk ) begin
    if (!sys_rst_n)
        cnt_v <= 11'd0;
    else if(cnt_h == H_TOTAL - 1'b1) begin
        if(cnt_v < V_TOTAL - 1'b1)
            cnt_v <= cnt_v + 1'b1;
        else 
            cnt_v <= 11'd0;
    end
end

endmodule
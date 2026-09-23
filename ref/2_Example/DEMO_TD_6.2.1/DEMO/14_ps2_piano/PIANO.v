module PIANO (reset, clk, ps2_clk, ps2_data ,ps2_data1);
   input reset; input clk;  input ps2_clk;  input ps2_data; 
   output[7:0] ps2_data1;
   reg ps2_clk_s;  reg enk;  reg ps2_clk_r;  reg flag;  reg always_one; 
   reg[6:0] lowtimecount;  reg[3:0] count; 
   reg[11:0] senddata; 
   integer TONE; 
 wire PreCLK; wire FullSpkS;  wire ps2_data_s; 

   reg[7:0] ps2_data1; reg[7:0] ps2_data2; reg[7:0] ps2_data4;
   parameter[10:0] ps2_f4 = 13'b10_11110100_0; 
   reg[8:0] q_data1_x;  reg[8:0] q_data2_x; reg[8:0] q_data3_x; reg[8:0] q_data4_x; 
   reg[7:0] q_data1;  reg[7:0] q_data2;  reg[7:0] q_data3;  reg[7:0] q_data4; 
  
   //--------------------------------------------
   parameter m2_st0=0,m2_new=1,m2_st1=2,m2_st2=3,m2_st3=4,m2_st4=5,m2_st5=6 ,m2_st6=7  ; 
   parameter m2_st7=8, m2_st8=9,m2_st9=10,m2_st10=11,m2_st11=12,m2_st12=13,m2_st13=14; 
   parameter m2_st14=15,m2_st15=16,m2_st16=17,m2_st17=18,m2_st18=19,m2_st19=20,m2_st20=21; 
   parameter m2_st21=22,m2_st22=23,m2_st23=24,m2_st24=25,m2_st25=26,m2_st26=27,m2_st27=28; 
   parameter m2_st28=29,m2_st29=30,m2_st30=31,m2_st31=32,m2_st32=33,m2_st33=34,m2_st34=35; 
   parameter m2_st35=36,m2_st36=37,m2_st37=38,m2_st38=39,m2_st39=40,m2_st40=41,m2_st41=42; 
   parameter m2_st42=43,m2_st43=44, m2_st44=45,m2_st45=46,m2_st46=47; 
   reg[5:0] m2_state;  reg[5:0] m2_nexts; integer Tone2;   reg[7:0] INDEXV; 
   //---------------------------------
   assign ps2_data_s = senddata[0] ;
   always @(reset)  begin
      if (reset==1'b0)  flag <= 1'b1 ;  end 
   always @(negedge clk or posedge reset)  begin : u1
      if (reset==1'b1)  begin lowtimecount <= {7{1'b0}} ; enk <= 1'b0 ;  ps2_clk_s <= 1'b1 ; 
      end   else  begin   if (flag == 1'b1)
                  begin   if (lowtimecount < 100)
                  begin   lowtimecount<=lowtimecount+1 ; ps2_clk_s<=1'b0 ;  end
                     else if (lowtimecount < 120)
                  begin   lowtimecount <= lowtimecount + 1;  enk <= 1'b1 ;  end
            else  begin   ps2_clk_s <= 1'b1 ;     enk <= 1'b0 ;             end 
         end   end  end 
   always @(negedge clk)   begin : u2
      ps2_clk_r <= ps2_clk ;   end 
   always @(negedge ps2_clk_r or posedge enk)   begin : u3
      if (enk == 1'b1)  begin  senddata <= {1'b1, ps2_f4} ;  end
      else  begin  senddata[11:0] <= {1'b1, senddata[11:1]} ;  end 
   end 
   //----------------------------------------------Receve part--------------------------

   always @(posedge enk or negedge ps2_clk_r)  begin : con
      if (enk == 1'b1)  begin  count <= {4{1'b0}} ;   end
      else   begin   if (count < 15)       //receive at rising_edfe
             begin   count <= count + 1 ;    end 
      end    end 
   always @(posedge clk)   begin : u4
      m2_state <= m2_nexts ;   end 
   always @(posedge ps2_clk_r)   begin : u5
      if (count < 10)   begin   m2_nexts <= m2_st0 ;   end
      else  begin
         case (m2_state)
            m2_st0 :  begin  m2_nexts<=m2_st1;      end
            m2_st1 :  begin  m2_nexts<=m2_st3;      end
            m2_st3 :  begin  m2_nexts<=m2_st4;      end//start
            m2_st4 :  begin  m2_nexts<=m2_st5;  q_data1_x<={ps2_data, q_data1_x[8:1]}; end
            m2_st5 :  begin  m2_nexts<=m2_st6;  q_data1_x<={ps2_data, q_data1_x[8:1]}; end
            m2_st6 :  begin  m2_nexts<=m2_st7;  q_data1_x<={ps2_data, q_data1_x[8:1]}; end
            m2_st7 :  begin  m2_nexts<=m2_st8;  q_data1_x<={ps2_data, q_data1_x[8:1]}; end
            m2_st8 :  begin  m2_nexts<=m2_st9;  q_data1_x<={ps2_data, q_data1_x[8:1]}; end
            m2_st9 :  begin  m2_nexts<=m2_st10; q_data1_x<={ps2_data, q_data1_x[8:1]}; end
            m2_st10 : begin  m2_nexts<=m2_st11; q_data1_x<={ps2_data, q_data1_x[8:1]}; end
            m2_st11 : begin  m2_nexts<=m2_st12; q_data1_x<={ps2_data, q_data1_x[8:1]}; end
            m2_st12 : begin  m2_nexts<=m2_st13; q_data1_x<={ps2_data, q_data1_x[8:1]};
                                                q_data1 <= q_data1_x[8:1]; end
            m2_st13 : begin  m2_nexts<=m2_st14; end
            m2_st14 : begin  m2_nexts<=m2_st15; end
            m2_st15 : begin  m2_nexts<=m2_st16; q_data2_x<={ps2_data, q_data2_x[8:1]}; end //data0 
            m2_st16 : begin  m2_nexts<=m2_st17; q_data2_x<={ps2_data, q_data2_x[8:1]}; end
            m2_st17 : begin  m2_nexts<=m2_st18; q_data2_x<={ps2_data, q_data2_x[8:1]}; end
            m2_st18 :
                     begin
                        m2_nexts <= m2_st19 ; 
                        q_data2_x <= {ps2_data, q_data2_x[8:1]} ; 
                        always_one <= ps2_data ; 
                     end
            m2_st19 :
                     begin
                        m2_nexts <= m2_st20 ; 
                        q_data2_x <= {ps2_data, q_data2_x[8:1]} ; 
                     end
            m2_st20 :
                     begin
                        m2_nexts <= m2_st21 ; 
                        q_data2_x <= {ps2_data, q_data2_x[8:1]} ; 
                     end
            m2_st21 :
                     begin
                        m2_nexts <= m2_st22 ; 
                        q_data2_x <= {ps2_data, q_data2_x[8:1]} ; 
                     end
            m2_st22 :
                     begin
                        m2_nexts <= m2_st23 ; 
                        q_data2_x <= {ps2_data, q_data2_x[8:1]} ; //data7
                     end
            m2_st23 :
                     begin
                        m2_nexts <= m2_st24 ; 
                        q_data2_x <= {ps2_data, q_data1_x[8:1]} ; 
                        q_data2 <= q_data2_x[8:1] ; 
                     end
            m2_st24 :
                     begin
                        if (always_one == 1'b1)
                        begin
                           m2_nexts <= m2_st25 ; //stop2
                        end
                        else
                        begin
                           m2_nexts <= m2_st14 ; 
                        end 
                     end
            m2_st25 :
                     begin
                        m2_nexts <= m2_st26 ; 
                     end
            m2_st26 :
                     begin
                        m2_nexts <= m2_st27 ; 
                        q_data3_x <= {ps2_data, q_data3_x[8:1]} ; //data0
                     end
            m2_st27 :
                     begin
                        m2_nexts <= m2_st28 ; 
                        q_data3_x <= {ps2_data, q_data3_x[8:1]} ; 
                     end
            m2_st28 :
                     begin
                        m2_nexts <= m2_st29 ; 
                        q_data3_x <= {ps2_data, q_data3_x[8:1]} ; 
                     end
            m2_st29 :
                     begin
                        m2_nexts <= m2_st30 ; 
                        q_data3_x <= {ps2_data, q_data3_x[8:1]} ; 
                     end
            m2_st30 :
                     begin
                        m2_nexts <= m2_st31 ; 
                        q_data3_x <= {ps2_data, q_data3_x[8:1]} ; 
                     end
            m2_st31 :
                     begin
                        m2_nexts <= m2_st32 ; 
                        q_data3_x <= {ps2_data, q_data3_x[8:1]} ; 
                     end
            m2_st32 :
                     begin
                        m2_nexts <= m2_st33 ; 
                        q_data3_x <= {ps2_data, q_data3_x[8:1]} ; 
                     end
            m2_st33 :
                     begin
                        m2_nexts <= m2_st34 ; 
                        q_data3_x <= {ps2_data, q_data3_x[8:1]} ; //data7
                     end
            m2_st34 :
                     begin
                        m2_nexts <= m2_st35 ; 
                        q_data3_x <= {ps2_data, q_data1_x[8:1]} ; 
                        q_data3 <= q_data3_x[8:1] ; 
                     end
            m2_st35 :
                     begin
                        m2_nexts <= m2_st36 ; //stop3    
                     end
            m2_st36 :
                     begin
                        m2_nexts <= m2_st37 ; //start
                     end
            m2_st37 :
                     begin
                        m2_nexts <= m2_st38 ; 
                        q_data4_x <= {ps2_data, q_data4_x[8:1]} ; //data0  
                     end
            m2_st38 :
                     begin
                        m2_nexts <= m2_st39 ; 
                        q_data4_x <= {ps2_data, q_data4_x[8:1]} ; 
                     end
            m2_st39 :
                     begin
                        m2_nexts <= m2_st40 ; 
                        q_data4_x <= {ps2_data, q_data4_x[8:1]} ; 
                     end
            m2_st40 :
                     begin
                        m2_nexts <= m2_st41 ; 
                        q_data4_x <= {ps2_data, q_data4_x[8:1]} ; 
                     end
            m2_st41 :
                     begin
                        m2_nexts <= m2_st42 ; 
                        q_data4_x <= {ps2_data, q_data4_x[8:1]} ; 
                     end
            m2_st42 :
                     begin
                        m2_nexts <= m2_st43 ; 
                        q_data4_x <= {ps2_data, q_data4_x[8:1]} ; 
                     end
            m2_st43 :
                     begin
                        m2_nexts <= m2_st44 ; 
                        q_data4_x <= {ps2_data, q_data4_x[8:1]} ; 
                     end
            m2_st44 :
                     begin
                        m2_nexts <= m2_st45 ; 
                        q_data4_x <= {ps2_data, q_data4_x[8:1]} ; //data7
                     end
            m2_st45 :
                     begin
                        m2_nexts <= m2_st46 ; 
                        q_data4_x <= {ps2_data, q_data1_x[8:1]} ; 
                        q_data4 <= q_data4_x[8:1] ; 
                     end
            m2_st46 :
                     begin
                        m2_nexts <= m2_st14 ; //stop4
                     end
            default :
                     begin
                     end
         endcase 
      end 
   end 
   
   always @(reset or q_data2)
   begin : u6
      if (reset == 1'b1)
      begin
         ps2_data1 <= {8{1'b0}} ; 
      end
      else
      begin
         ps2_data1 <= q_data2 ; 
      end 
   end 
endmodule 
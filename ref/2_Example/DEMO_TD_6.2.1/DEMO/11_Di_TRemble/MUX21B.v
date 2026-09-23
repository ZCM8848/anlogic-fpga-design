module MUX21B (A,S,Y1,Y2);
     input A,S;
     output Y1,Y2; 
      reg Y1,Y2;      
     always @(A,S)  begin //¿éÓï¾äÆğÊ¼
         if (S==0) begin  Y1 <= A; Y2<=0;  end
   else            begin  Y2 <= A; Y1<=0;  end
   end                                //¿éÓï¾ä½áÊø
    endmodule

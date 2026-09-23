module MUX21a (A,B,S,Y);
     input [7:0] A,B;
     input S;
     output [7:0] Y; 
      reg [7:0]Y;      
     always @(A,B,S)  begin //块语句起始
         if (S==0)   Y <= A;      //当SEL==0成立，即(SEL==0)=1时，Y=A;
   else              Y <= B;      //当(SEL==1)为真，则Y=B;
   end                                //块语句结束
    endmodule

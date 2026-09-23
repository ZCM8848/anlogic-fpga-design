module M8B (R,A,B);
   parameter S=4;
   output[2*S:1] R ; 
   input[S:1] A,B ; 
   reg[2*S:1] R,AT; reg[S:1] BT,CT;
   always @(A,B )   begin
    R=0; AT = {{S{1'B0}},A};
    BT = B;  CT = S;
    for(CT=S; CT>0; CT=CT-1)
      begin  if(BT[1]) R=R+AT;
        AT = AT<<1;   //左移1位
        BT = BT>>1;   //右移1位
end  end 
endmodule
module traffic(clk, r1, y1, g1, r2, y2, g2);
   input      clk;
   output     r1;
   reg        r1;
   output     y1;
   reg        y1;
   output     g1;
   reg        g1;
   output     r2;
   reg        r2;
   output     y2;
   reg        y2;
   output     g2;
   reg        g2;
   parameter  yellow_time = 5;
   parameter  green_time = 20;
   reg [1:0]  state;
   reg [4:0]  count;
   always @(posedge clk)
      
         case (state)
            0 :
               begin
                  r1 <= 1'b0;
                  y1 <= 1'b0;
                  g1 <= 1'b1;
                  r2 <= 1'b1;
                  y2 <= 1'b0;
                  g2 <= 1'b0;
               end
            1 :
               begin
                  r1 <= 1'b0;
                  y1 <= 1'b1;
                  g1 <= 1'b0;
                  r2 <= 1'b1;
                  y2 <= 1'b0;
                  g2 <= 1'b0;
               end
            2 :
               begin
                  r1 <= 1'b1;
                  y1 <= 1'b0;
                  g1 <= 1'b0;
                  r2 <= 1'b0;
                  y2 <= 1'b0;
                  g2 <= 1'b1;
               end
            default :
               begin
                  r1 <= 1'b1;
                  y1 <= 1'b0;
                  g1 <= 1'b0;
                  r2 <= 1'b0;
                  y2 <= 1'b1;
                  g2 <= 1'b0;
               end
         endcase
   
   always @(posedge clk)       
      begin
         if (count == 5'd0)
         begin
            if (state == 2'd3)
               state <= 2'd0;
            else
               state <= state + 1'b1;
            case (state)
               2'b00 :
                  count <= yellow_time;
               2'b01 :
                  count <= green_time;
               2'b10 :
                  count <= yellow_time;
               default :
                  count <= green_time;
            endcase
         end
         else
            count = count - 1'b1;
      end
   
endmodule

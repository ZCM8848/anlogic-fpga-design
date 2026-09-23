module  VGA(CLK,key_signal,HS,VS,R,G,B,rst,ting_flag,add,date);
    input CLK,rst;
    input [7:0] key_signal; 
    input [7:0] date;
	output [7:0]add;
    output HS,VS,R,G,B;
    output ting_flag;
    reg ting_flag=1;
    reg [9:0] hcnt,vcnt;
    reg [2:0] rgb;              
    reg HS=1'b0,VS=1'b0;
    reg [9:0] x=160,y=240;
    reg key_flag=1'b0;
    reg [2:0] bita;
    reg num=0,win_flag=0,win_flag1=0;
    reg 
		z00=0,z01=0,z02=0,z03=0,z04=0,z05=0,z06=0,z07=0,z08=0,z09=0,z010=0,
		z10=0,z11=0,z12=0,z13=0,z14=0,z15=0,z16=0,z17=0,z18=0,z19=0,z110=0,
        z20=0,z21=0,z22=0,z23=0,z24=0,z25=0,z26=0,z27=0,z28=0,z29=0,z210=0,
        z30=0,z31=0,z32=0,z33=0,z34=0,z35=0,z36=0,z37=0,z38=0,z39=0,z310=0,
        z40=0,z41=0,z42=0,z43=0,z44=0,z45=0,z46=0,z47=0,z48=0,z49=0,z410=0,
        z50=0,z51=0,z52=0,z53=0,z54=0,z55=0,z56=0,z57=0,z58=0,z59=0,z510=0,
        z60=0,z61=0,z62=0,z63=0,z64=0,z65=0,z66=0,z67=0,z68=0,z69=0,z610=0,
        z70=0,z71=0,z72=0,z73=0,z74=0,z75=0,z76=0,z77=0,z78=0,z79=0,z710=0,
        z80=0,z81=0,z82=0,z83=0,z84=0,z85=0,z86=0,z87=0,z88=0,z89=0,z810=0,
        z90=0,z91=0,z92=0,z93=0,z94=0,z95=0,z96=0,z97=0,z98=0,z99=0,z910=0,
        z100=0,z101=0,z102=0,z103=0,z104=0,z105=0,z106=0,z107=0,z108=0,z109=0,z1010=0,//hei qi biao zhi wei
																						
        v00=0,v01=0,v02=0,v03=0,v04=0,v05=0,v06=0,v07=0,v08=0,v09=0,v010=0,
		v10=0,v11=0,v12=0,v13=0,v14=0,v15=0,v16=0,v17=0,v18=0,v19=0,v110=0,
        v20=0,v21=0,v22=0,v23=0,v24=0,v25=0,v26=0,v27=0,v28=0,v29=0,v210=0,
        v30=0,v31=0,v32=0,v33=0,v34=0,v35=0,v36=0,v37=0,v38=0,v39=0,v310=0,
        v40=0,v41=0,v42=0,v43=0,v44=0,v45=0,v46=0,v47=0,v48=0,v49=0,v410=0,
        v50=0,v51=0,v52=0,v53=0,v54=0,v55=0,v56=0,v57=0,v58=0,v59=0,v510=0,
        v60=0,v61=0,v62=0,v63=0,v64=0,v65=0,v66=0,v67=0,v68=0,v69=0,v610=0,
        v70=0,v71=0,v72=0,v73=0,v74=0,v75=0,v76=0,v77=0,v78=0,v79=0,v710=0,
        v80=0,v81=0,v82=0,v83=0,v84=0,v85=0,v86=0,v87=0,v88=0,v89=0,v810=0,
        v90=0,v91=0,v92=0,v93=0,v94=0,v95=0,v96=0,v97=0,v98=0,v99=0,v910=0,
        v100=0,v101=0,v102=0,v103=0,v104=0,v105=0,v106=0,v107=0,v108=0,v109=0,v1010=0;//hong qi biao zhi wei 
 ////////////////////////////VGA shi xu/////////////////////////////////////       
 always@(posedge CLK)
      begin
          if(hcnt==800) hcnt<=0;
          else hcnt<=hcnt+1;
      end
 always@(posedge CLK)
      begin
          if(hcnt<96) HS<=0;
          else  HS<=1;
      end
 always@(posedge CLK)
      begin
         if(hcnt==800)   
          begin
             vcnt<=vcnt+1;
             if(vcnt==525) vcnt<=0;
          end
      end
always@(posedge CLK)
      begin
          if(vcnt<2) VS<=0;
          else VS<=1;
      end
////////////////////////////////////////////////////////////////////////////////    
    
wire [9:0] x_zhou,y_zhou;
wire [9:0] add;
assign x_zhou=hcnt-144;
assign y_zhou=vcnt-35;
assign add=(x_zhou-435)/8+(y_zhou-120)*10;

always@(posedge CLK,negedge rst)
	begin
		if(!rst)
			begin
				rgb<=3'b110;
			end
		else
        begin
			if(x_zhou>10&&x_zhou<310&&y_zhou>90&&y_zhou<390)
			  begin
				if(y_zhou%30==0||y_zhou%30==1||y_zhou%30==2||x_zhou%30==10||x_zhou%30==11||x_zhou%30==12)
					rgb<=3'b100;	//qi ge xian shi
				else
					if(x_zhou>(x-10)&&x_zhou<(x+10)&&y_zhou>(y-10)&&y_zhou<(y+10))
						begin
							if(key_flag==1)
								if(num%2==0)
									rgb<=3'b100;
								else
									rgb<=3'b010;
							else
								rgb<=3'b110; //guan biao de xian shi
						end
					 						
					else	
					
						if(x_zhou>10&&x_zhou<20&&y_zhou>90&&y_zhou<100)
								if(z00==1) rgb<=3'b001;else if(v00==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>10&&x_zhou<20&&y_zhou>110&&y_zhou<130)
								if(z01==1) rgb<=3'b001;else if(v01==1) rgb<=3'b000;else rgb<=3'b111;
				else	if(x_zhou>10&&x_zhou<20&&y_zhou>140&&y_zhou<160)
								if(z02==1) rgb<=3'b001;else if(v02==1) rgb<=3'b000;else rgb<=3'b111;
				else	if(x_zhou>10&&x_zhou<20&&y_zhou>170&&y_zhou<190)
								if(z03==1) rgb<=3'b001;else if(v03==1) rgb<=3'b000;else rgb<=3'b111;													
				else 	if(x_zhou>10&&x_zhou<20&&y_zhou>200&&y_zhou<220)
								if(z04==1) rgb<=3'b001;else if(v04==1) rgb<=3'b000;else rgb<=3'b111;
				else	if(x_zhou>10&&x_zhou<20&&y_zhou>230&&y_zhou<250)
								if(z05==1) rgb<=3'b001;else if(v05==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>10&&x_zhou<20&&y_zhou>260&&y_zhou<280)
								if(z06==1) rgb<=3'b001;else if(v06==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>10&&x_zhou<20&&y_zhou>290&&y_zhou<310)
								if(z07==1) rgb<=3'b001;else if(v07==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>10&&x_zhou<20&&y_zhou>320&&y_zhou<340)
								if(z08==1) rgb<=3'b001;else if(v08==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>10&&x_zhou<20&&y_zhou>350&&y_zhou<370)
								if(z09==1) rgb<=3'b001;else if(v09==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>10&&x_zhou<20&&y_zhou>380&&y_zhou<390)
								if(z010==1) rgb<=3'b001;else if(v010==1) rgb<=3'b000;else rgb<=3'b111;//111111111
						
					else	
						
						if(x_zhou>30&&x_zhou<50&&y_zhou>90&&y_zhou<100)
								if(z10==1) rgb<=3'b001;else if(v10==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>30&&x_zhou<50&&y_zhou>110&&y_zhou<130)
								if(z11==1) rgb<=3'b001;else if(v11==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>30&&x_zhou<50&&y_zhou>140&&y_zhou<160)
								if(z12==1) rgb<=3'b001;else if(v12==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>30&&x_zhou<50&&y_zhou>170&&y_zhou<190)
								if(z13==1) rgb<=3'b001;else if(v13==1) rgb<=3'b000;else rgb<=3'b111;															
				else 	if(x_zhou>30&&x_zhou<50&&y_zhou>200&&y_zhou<220)
								if(z14==1) rgb<=3'b001;else if(v14==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>30&&x_zhou<50&&y_zhou>230&&y_zhou<250)
								if(z15==1) rgb<=3'b001;else if(v15==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>30&&x_zhou<50&&y_zhou>260&&y_zhou<280)
								if(z16==1) rgb<=3'b001;else if(v16==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>30&&x_zhou<50&&y_zhou>290&&y_zhou<310)
								if(z17==1) rgb<=3'b001;else if(v17==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>30&&x_zhou<50&&y_zhou>320&&y_zhou<340)
								if(z18==1) rgb<=3'b001;else if(v18==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>30&&x_zhou<50&&y_zhou>350&&y_zhou<370)
								if(z19==1) rgb<=3'b001;else if(v19==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>30&&x_zhou<50&&y_zhou>380&&y_zhou<390)
								if(z110==1) rgb<=3'b001;else if(v110==1) rgb<=3'b000;else rgb<=3'b111;//222222222
						
					else	
						if(x_zhou>60&&x_zhou<80&&y_zhou>90&&y_zhou<100)
								if(z20==1) rgb<=3'b001;else if(v20==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>60&&x_zhou<80&&y_zhou>110&&y_zhou<130)
								if(z21==1) rgb<=3'b001;else if(v21==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>60&&x_zhou<80&&y_zhou>140&&y_zhou<160)
								if(z22==1) rgb<=3'b001;else if(v22==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>60&&x_zhou<80&&y_zhou>170&&y_zhou<190)
								if(z23==1) rgb<=3'b001;else if(v23==1) rgb<=3'b000;else rgb<=3'b111;															
				else 	if(x_zhou>60&&x_zhou<80&&y_zhou>200&&y_zhou<220)
								if(z24==1) rgb<=3'b001;else if(v24==1) rgb<=3'b000;else rgb<=3'b111;
				else	if(x_zhou>60&&x_zhou<80&&y_zhou>230&&y_zhou<250)
								if(z25==1) rgb<=3'b001;else if(v25==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>60&&x_zhou<80&&y_zhou>260&&y_zhou<280)
								if(z26==1) rgb<=3'b001;else if(v26==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>60&&x_zhou<80&&y_zhou>290&&y_zhou<310)
								if(z27==1) rgb<=3'b001;else if(v27==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>60&&x_zhou<80&&y_zhou>320&&y_zhou<340)
								if(z28==1) rgb<=3'b001;else if(v28==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>60&&x_zhou<80&&y_zhou>350&&y_zhou<370)
								if(z29==1) rgb<=3'b001;else if(v29==1) rgb<=3'b000;else rgb<=3'b111;
			    else	if(x_zhou>60&&x_zhou<80&&y_zhou>380&&y_zhou<390)
								if(z210==1) rgb<=3'b001;else if(v210==1) rgb<=3'b000;else rgb<=3'b111;//333333333333
						
					else	
						
						if(x_zhou>90&&x_zhou<110&&y_zhou>90&&y_zhou<100)
								if(z30==1) rgb<=3'b001;else if(v30==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>90&&x_zhou<110&&y_zhou>110&&y_zhou<130)
								if(z31==1) rgb<=3'b001;else if(v31==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>90&&x_zhou<110&&y_zhou>140&&y_zhou<160)
								if(z32==1) rgb<=3'b001;else if(v32==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>90&&x_zhou<110&&y_zhou>170&&y_zhou<190)
								if(z33==1) rgb<=3'b001;else if(v33==1) rgb<=3'b000;else rgb<=3'b111;														
				else 	if(x_zhou>90&&x_zhou<110&&y_zhou>200&&y_zhou<220)
								if(z34==1) rgb<=3'b001;else if(v34==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>90&&x_zhou<110&&y_zhou>230&&y_zhou<250)
								if(z35==1) rgb<=3'b001;else if(v35==1) rgb<=3'b000;else rgb<=3'b111;
				else	if(x_zhou>90&&x_zhou<110&&y_zhou>260&&y_zhou<280)
								if(z36==1) rgb<=3'b001;else if(v36==1) rgb<=3'b000;else rgb<=3'b111;
				else	if(x_zhou>90&&x_zhou<110&&y_zhou>290&&y_zhou<310)
								if(z37==1) rgb<=3'b001;else if(v37==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>90&&x_zhou<110&&y_zhou>320&&y_zhou<340)
								if(z38==1) rgb<=3'b001;else if(v38==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>90&&x_zhou<110&&y_zhou>350&&y_zhou<370)
								if(z39==1) rgb<=3'b001;else if(v39==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>90&&x_zhou<110&&y_zhou>380&&y_zhou<390)
								if(z310==1) rgb<=3'b001;else if(v310==1) rgb<=3'b000;else rgb<=3'b111;//44444444444444
						
					else	
						
						if(x_zhou>120&&x_zhou<140&&y_zhou>90&&y_zhou<100)
								if(z40==1) rgb<=3'b001;else if(v40==1) rgb<=3'b000;else rgb<=3'b111;
				else	if(x_zhou>120&&x_zhou<140&&y_zhou>110&&y_zhou<130)
								if(z41==1) rgb<=3'b001;else if(v41==1) rgb<=3'b000;else rgb<=3'b111;
				else	if(x_zhou>120&&x_zhou<140&&y_zhou>140&&y_zhou<160)
								if(z42==1) rgb<=3'b001;else if(v42==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>120&&x_zhou<140&&y_zhou>170&&y_zhou<190)
								if(z43==1) rgb<=3'b001;else if(v43==1) rgb<=3'b000;else rgb<=3'b111;																
				else 	if(x_zhou>120&&x_zhou<140&&y_zhou>200&&y_zhou<220)
								if(z44==1) rgb<=3'b001;else if(v44==1) rgb<=3'b000;else rgb<=3'b111;
				else	if(x_zhou>120&&x_zhou<140&&y_zhou>230&&y_zhou<250)
								if(z45==1) rgb<=3'b001;else if(v45==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>120&&x_zhou<140&&y_zhou>260&&y_zhou<280)
								if(z46==1) rgb<=3'b001;else if(v46==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>120&&x_zhou<140&&y_zhou>290&&y_zhou<310)
								if(z47==1) rgb<=3'b001;else if(v47==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>120&&x_zhou<140&&y_zhou>320&&y_zhou<340)
								if(z48==1) rgb<=3'b001;else if(v48==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>120&&x_zhou<140&&y_zhou>350&&y_zhou<370)
								if(z49==1) rgb<=3'b001;else if(v49==1) rgb<=3'b000;else rgb<=3'b111;
				else	if(x_zhou>120&&x_zhou<140&&y_zhou>380&&y_zhou<390)
								if(z410==1) rgb<=3'b001;else if(v410==1) rgb<=3'b000;else rgb<=3'b111;//55555555555555
					else	
						
						if(x_zhou>150&&x_zhou<170&&y_zhou>90&&y_zhou<100)
								if(z50==1) rgb<=3'b001;else if(v50==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>150&&x_zhou<170&&y_zhou>110&&y_zhou<130)
								if(z51==1) rgb<=3'b001;else if(v51==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>150&&x_zhou<170&&y_zhou>140&&y_zhou<160)
								if(z52==1) rgb<=3'b001;else if(v52==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>150&&x_zhou<170&&y_zhou>170&&y_zhou<190)
								if(z53==1) rgb<=3'b001;else if(v53==1) rgb<=3'b000;else rgb<=3'b111;															
				else 	if(x_zhou>150&&x_zhou<170&&y_zhou>200&&y_zhou<220)
								if(z54==1) rgb<=3'b001;else if(v54==1) rgb<=3'b000;else rgb<=3'b111;
				else    if((x_zhou-160)*(x_zhou-160)+(y_zhou-240)*(y_zhou-240)<130)
//				else 	if(x_zhou>150&&x_zhou<170&&y_zhou>230&&y_zhou<250)
								if(z55==1) rgb<=3'b001;else if(v55==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>150&&x_zhou<170&&y_zhou>260&&y_zhou<280)
								if(z56==1) rgb<=3'b001;else if(v56==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>150&&x_zhou<170&&y_zhou>290&&y_zhou<310)
								if(z57==1) rgb<=3'b001;else if(v57==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>150&&x_zhou<170&&y_zhou>320&&y_zhou<340)
								if(z58==1) rgb<=3'b001;else if(v58==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>150&&x_zhou<170&&y_zhou>350&&y_zhou<370)
								if(z59==1) rgb<=3'b001;else if(v59==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>150&&x_zhou<170&&y_zhou>380&&y_zhou<390)
								if(z510==1) rgb<=3'b001;else if(v510==1) rgb<=3'b000;else rgb<=3'b111;//66666666666666
								
//		
//						if((x_zhou-161)*(x_zhou-161)+(y_zhou-91)*(y_zhou-91)<150)
//								if(z50==1) rgb<=3'b001;else if(v50==1) rgb<=3'b000;else rgb<=3'b111;
//				else 	if((x_zhou-161)*(x_zhou-161)+(y_zhou-121)*(y_zhou-121)<150)
//								if(z51==1) rgb<=3'b001;else if(v51==1) rgb<=3'b000;else rgb<=3'b111;
//				else 	if((x_zhou-161)*(x_zhou-161)+(y_zhou-151)*(y_zhou-151)<150)
//								if(z52==1) rgb<=3'b001;else if(v52==1) rgb<=3'b000;else rgb<=3'b111;
//				else 	if((x_zhou-161)*(x_zhou-161)+(y_zhou-181)*(y_zhou-181)<150)
//								if(z53==1) rgb<=3'b001;else if(v53==1) rgb<=3'b000;else rgb<=3'b111;															
//				else 	if((x_zhou-161)*(x_zhou-161)+(y_zhou-211)*(y_zhou-211)<150)
//								if(z54==1) rgb<=3'b001;else if(v54==1) rgb<=3'b000;else rgb<=3'b111;
//				else 	if((x_zhou-161)*(x_zhou-161)+(y_zhou-241)*(y_zhou-241)<150)
//								if(z55==1) rgb<=3'b001;else if(v55==1) rgb<=3'b000;else rgb<=3'b111;
//				else 	if((x_zhou-161)*(x_zhou-161)+(y_zhou-271)*(y_zhou-271)<150)
//								if(z56==1) rgb<=3'b001;else if(v56==1) rgb<=3'b000;else rgb<=3'b111;
//				else 	if((x_zhou-161)*(x_zhou-161)+(y_zhou-301)*(y_zhou-301)<150)
//								if(z57==1) rgb<=3'b001;else if(v57==1) rgb<=3'b000;else rgb<=3'b111;
//				else 	if((x_zhou-161)*(x_zhou-161)+(y_zhou-331)*(y_zhou-331)<150)
//								if(z58==1) rgb<=3'b001;else if(v58==1) rgb<=3'b000;else rgb<=3'b111;
//				else 	if((x_zhou-161)*(x_zhou-161)+(y_zhou-361)*(y_zhou-361)<150)
//								if(z59==1) rgb<=3'b001;else if(v59==1) rgb<=3'b000;else rgb<=3'b111;
//				else 	if((x_zhou-161)*(x_zhou-161)+(y_zhou-391)*(y_zhou-391)<150)
//								if(z510==1) rgb<=3'b001;else if(v510==1) rgb<=3'b000;else rgb<=3'b111;//66666666666666
						
					else	
						
					 	if(x_zhou>180&&x_zhou<200&&y_zhou>90&&y_zhou<100)
								if(z60==1) rgb<=3'b001;else if(v60==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>180&&x_zhou<200&&y_zhou>110&&y_zhou<130)
								if(z61==1) rgb<=3'b001;else if(v61==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>180&&x_zhou<200&&y_zhou>140&&y_zhou<160)
								if(z62==1) rgb<=3'b001;else if(v62==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>180&&x_zhou<200&&y_zhou>170&&y_zhou<190)
								if(z63==1) rgb<=3'b001;else if(v63==1) rgb<=3'b000;else rgb<=3'b111;														
				else 	if(x_zhou>180&&x_zhou<200&&y_zhou>200&&y_zhou<220)
								if(z64==1) rgb<=3'b001;else if(v64==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>180&&x_zhou<200&&y_zhou>230&&y_zhou<250)
								if(z65==1) rgb<=3'b001;else if(v65==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>180&&x_zhou<200&&y_zhou>260&&y_zhou<280)
								if(z66==1) rgb<=3'b001;else if(v66==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>180&&x_zhou<200&&y_zhou>290&&y_zhou<310)
								if(z67==1) rgb<=3'b001;else if(v67==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>180&&x_zhou<200&&y_zhou>320&&y_zhou<340)
								if(z68==1) rgb<=3'b001;else if(v68==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>180&&x_zhou<200&&y_zhou>350&&y_zhou<370)
								if(z69==1) rgb<=3'b001;else if(v69==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>180&&x_zhou<200&&y_zhou>380&&y_zhou<390)
								if(z610==1) rgb<=3'b001;else if(v610==1) rgb<=3'b000;else rgb<=3'b111;//77777777777777777
						
					else	
						
					 	if(x_zhou>210&&x_zhou<230&&y_zhou>90&&y_zhou<100)
								if(z70==1) rgb<=3'b001;else if(v70==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>210&&x_zhou<230&&y_zhou>110&&y_zhou<130)
								if(z71==1) rgb<=3'b001;else if(v71==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>210&&x_zhou<230&&y_zhou>140&&y_zhou<160)
								if(z72==1) rgb<=3'b001;else if(v72==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>210&&x_zhou<230&&y_zhou>170&&y_zhou<190)
								if(z73==1) rgb<=3'b001;else if(v73==1) rgb<=3'b000;else rgb<=3'b111;														
				else 	if(x_zhou>210&&x_zhou<230&&y_zhou>200&&y_zhou<220)
								if(z74==1) rgb<=3'b001;else if(v74==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>210&&x_zhou<230&&y_zhou>230&&y_zhou<250)
								if(z75==1) rgb<=3'b001;else if(v75==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>210&&x_zhou<230&&y_zhou>260&&y_zhou<280)
								if(z76==1) rgb<=3'b001;else if(v76==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>210&&x_zhou<230&&y_zhou>290&&y_zhou<310)
								if(z77==1) rgb<=3'b001;else if(v77==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>210&&x_zhou<230&&y_zhou>320&&y_zhou<340)
								if(z78==1) rgb<=3'b001;else if(v78==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>210&&x_zhou<230&&y_zhou>350&&y_zhou<370)
								if(z79==1) rgb<=3'b001;else if(v79==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>210&&x_zhou<230&&y_zhou>380&&y_zhou<390)
								if(z710==1) rgb<=3'b001;else if(v710==1) rgb<=3'b000;else rgb<=3'b111;//888888888888888888
						
					else	
						
					 	if(x_zhou>240&&x_zhou<260&&y_zhou>90&&y_zhou<100)
								if(z80==1) rgb<=3'b001;else if(v80==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>240&&x_zhou<260&&y_zhou>110&&y_zhou<130)
								if(z81==1) rgb<=3'b001;else if(v81==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>240&&x_zhou<260&&y_zhou>140&&y_zhou<160)
								if(z82==1) rgb<=3'b001;else if(v82==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>240&&x_zhou<260&&y_zhou>170&&y_zhou<190)
								if(z83==1) rgb<=3'b001;else if(v83==1) rgb<=3'b000;else rgb<=3'b111;														
				else 	if(x_zhou>240&&x_zhou<260&&y_zhou>200&&y_zhou<220)
								if(z84==1) rgb<=3'b001;else if(v84==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>240&&x_zhou<260&&y_zhou>230&&y_zhou<250)
								if(z85==1) rgb<=3'b001;else if(v85==1) rgb<=3'b000;else rgb<=3'b111;
			    else 	if(x_zhou>240&&x_zhou<260&&y_zhou>260&&y_zhou<280)
								if(z86==1) rgb<=3'b001;else if(v86==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>240&&x_zhou<260&&y_zhou>290&&y_zhou<310)
								if(z87==1) rgb<=3'b001;else if(v87==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>240&&x_zhou<260&&y_zhou>320&&y_zhou<340)
								if(z88==1) rgb<=3'b001;else if(v88==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>240&&x_zhou<260&&y_zhou>350&&y_zhou<370)
								if(z89==1) rgb<=3'b001;else if(v89==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>240&&x_zhou<260&&y_zhou>380&&y_zhou<390)
								if(z810==1) rgb<=3'b001;else if(v810==1) rgb<=3'b000;else rgb<=3'b111;//99999999999999999
						
					else	
						
					 	if(x_zhou>270&&x_zhou<290&&y_zhou>90&&y_zhou<100)
								if(z90==1) rgb<=3'b001;else if(v90==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>270&&x_zhou<290&&y_zhou>110&&y_zhou<130)
								if(z91==1) rgb<=3'b001;else if(v91==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>270&&x_zhou<290&&y_zhou>140&&y_zhou<160)
								if(z92==1) rgb<=3'b001;else if(v92==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>270&&x_zhou<290&&y_zhou>170&&y_zhou<190)
								if(z93==1) rgb<=3'b001;else if(v93==1) rgb<=3'b000;else rgb<=3'b111;															
				else 	if(x_zhou>270&&x_zhou<290&&y_zhou>200&&y_zhou<220)
								if(z94==1) rgb<=3'b001;else if(v94==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>270&&x_zhou<290&&y_zhou>230&&y_zhou<250)
								if(z95==1) rgb<=3'b001;else if(v95==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>270&&x_zhou<290&&y_zhou>260&&y_zhou<280)
								if(z96==1) rgb<=3'b001;else if(v96==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>270&&x_zhou<290&&y_zhou>290&&y_zhou<310)
								if(z97==1) rgb<=3'b001;else if(v97==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>270&&x_zhou<290&&y_zhou>320&&y_zhou<340)
								if(z98==1) rgb<=3'b001;else if(v98==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>270&&x_zhou<290&&y_zhou>350&&y_zhou<370)
								if(z99==1) rgb<=3'b001;else if(v99==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>270&&x_zhou<290&&y_zhou>380&&y_zhou<390)
								if(z910==1) rgb<=3'b001;else if(v910==1) rgb<=3'b000;else rgb<=3'b111;//10
						
					else	
					 	if(x_zhou>300&&x_zhou<310&&y_zhou>90&&y_zhou<100)
								if(z100==1) rgb<=3'b001;else if(v100==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>300&&x_zhou<310&&y_zhou>110&&y_zhou<130)
								if(z101==1) rgb<=3'b001;else if(v101==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>300&&x_zhou<310&&y_zhou>140&&y_zhou<160)
								if(z102==1) rgb<=3'b001;else if(v102==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>300&&x_zhou<310&&y_zhou>170&&y_zhou<190)
								if(z103==1) rgb<=3'b001;else if(v103==1) rgb<=3'b000;else rgb<=3'b111;														
				else 	if(x_zhou>300&&x_zhou<310&&y_zhou>200&&y_zhou<220)
								if(z104==1) rgb<=3'b001;else if(v104==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>300&&x_zhou<310&&y_zhou>230&&y_zhou<250)
								if(z105==1) rgb<=3'b001;else if(v105==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>300&&x_zhou<310&&y_zhou>260&&y_zhou<280)
								if(z106==1) rgb<=3'b001;else if(v106==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>300&&x_zhou<310&&y_zhou>290&&y_zhou<310)
								if(z107==1) rgb<=3'b001;else if(v107==1) rgb<=3'b000;else rgb<=3'b111;
				else	if(x_zhou>300&&x_zhou<310&&y_zhou>320&&y_zhou<340)
								if(z108==1) rgb<=3'b001;else if(v108==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>300&&x_zhou<310&&y_zhou>350&&y_zhou<370)
								if(z109==1) rgb<=3'b001;else if(v109==1) rgb<=3'b000;else rgb<=3'b111;
				else 	if(x_zhou>300&&x_zhou<310&&y_zhou>380&&y_zhou<390)
								if(z1010==1) rgb<=3'b001;else if(v1010==1) rgb<=3'b000;else rgb<=3'b111;//11						
				else
						rgb<=3'b111;
			end
		else
		    if(x_zhou>0&&x_zhou<640&&y_zhou>0&&y_zhou<10||x_zhou>0&&x_zhou<10&&y_zhou>0&&y_zhou<480||x_zhou>0&&x_zhou<640&&y_zhou>470&&y_zhou<480||x_zhou>630&&x_zhou<640&&y_zhou>0&&y_zhou<480)
						rgb<=3'b011;
		else				
//////////////////////////////you bian ji shi ////////////////////////////////////////////////////////////			
			if(x_zhou>410&&x_zhou<540&&y_zhou>90&&y_zhou<390)
				begin
									//							if(win_flag==1&&x_zhou>440&&x_zhou<505&&y_zhou>175&&y_zhou<188) rgb<=3'b011;else
									//							if(win_flag==1&&x_zhou>440&&x_zhou<453&&y_zhou>188&&y_zhou<227) rgb<=3'b011;else
									//							if(win_flag==1&&x_zhou>440&&x_zhou<505&&y_zhou>227&&y_zhou<240) rgb<=3'b011;else
									//							if(win_flag==1&&x_zhou>440&&x_zhou<453&&y_zhou>240&&y_zhou<280) rgb<=3'b011;else	//E
									//							if(win_flag==1&&x_zhou>440&&x_zhou<505&&y_zhou>280&&y_zhou<293) rgb<=3'b011;else
									//							rgb<=3'b010;
					if(x_zhou>=435&&x_zhou<=515&&y_zhou>=120&&y_zhou<=200)
						begin
							if(win_flag1==1)
									begin
										rgb[0]<=date[bita];
										rgb[1]<=0;
										rgb[2]<=0;
										bita<=bita+1;
									end	
							else
								if(win_flag==1)
									begin
										rgb[1]<=date[bita];
										rgb[0]<=0;
										rgb[2]<=0;
										bita<=bita+1;
									end
								else
									rgb<=3'b010;
						end
					else if(x_zhou>=410&&x_zhou<=540&&y_zhou>=230&&y_zhou<=250)
							rgb<=3'b001;
												else if(x_zhou>=410&&x_zhou<=540&&y_zhou>=250&&y_zhou<=270)
							rgb<=3'b000;
												else if(x_zhou>=410&&x_zhou<=540&&y_zhou>=270&&y_zhou<=290)
							rgb<=3'b011;
												else if(x_zhou>=410&&x_zhou<=540&&y_zhou>=290&&y_zhou<=310)
							rgb<=3'b100;
												else if(x_zhou>=410&&x_zhou<=540&&y_zhou>=310&&y_zhou<=330)
							rgb<=3'b101;
												else if(x_zhou>=410&&x_zhou<=540&&y_zhou>=330&&y_zhou<=350)
							rgb<=3'b110;
												else if(x_zhou>=410&&x_zhou<=540&&y_zhou>=350&&y_zhou<=370)
							rgb<=3'b111;
												else if(x_zhou>=410&&x_zhou<=540&&y_zhou>=370&&y_zhou<=390)
							rgb<=3'b010;
					else
						rgb<=3'b010;
				end
			else
				rgb<=3'b000;
		end		 
	end
////////////////////////////////////YOU XI GUI ZHE////////////////////////////////////////////////////////////////////////////////////
always@(posedge CLK,negedge rst)
	if(!rst)
		begin
			win_flag=0;
			win_flag1=0;
		end
	else
	begin
		if(z22==1&&z23==1&&z21==1&&z24==1&&z20==1||z22==1&&z23==1&&z24==1&&z25==1&&z21==1||z22==1&&z23==1&&z24==1&&z25==1&&z26==1||23==1&&z24==1&&z25==1&&z26==1&&z27==1||z24==1&&z25==1&&z26==1&&z27==1&&z28==1||z28==1&&z25==1&&z26==1&&z27==1&&z29==1||z28==1&&z210==1&&z26==1&&z27==1&&z29==1) win_flag1<=1;
	else	if(z32==1&&z33==1&&z31==1&&z34==1&&z30==1||z32==1&&z33==1&&z34==1&&z35==1&&z31==1||z32==1&&z33==1&&z34==1&&z35==1&&z36==1||z33==1&&z34==1&&z35==1&&z36==1&&z37==1||z34==1&&z35==1&&z36==1&&z37==1&&z38==1||z38==1&&z35==1&&z36==1&&z37==1&&z39==1||z38==1&&z310==1&&z36==1&&z37==1&&z39==1) win_flag1<=1;
	else	if(z42==1&&z43==1&&z41==1&&z44==1&&z40==1||z42==1&&z43==1&&z44==1&&z45==1&&z41==1||z42==1&&z43==1&&z44==1&&z45==1&&z46==1||z43==1&&z44==1&&z45==1&&z46==1&&z47==1||z44==1&&z45==1&&z46==1&&z47==1&&z48==1||z48==1&&z45==1&&z46==1&&z47==1&&z49==1||z48==1&&z410==1&&z46==1&&z47==1&&z49==1) win_flag1<=1;
	else	if(z52==1&&z53==1&&z51==1&&z54==1&&z50==1||z52==1&&z53==1&&z54==1&&z55==1&&z51==1||z52==1&&z53==1&&z54==1&&z55==1&&z56==1||z53==1&&z54==1&&z55==1&&z56==1&&z57==1||z54==1&&z55==1&&z56==1&&z57==1&&z58==1||z58==1&&z55==1&&z56==1&&z57==1&&z59==1||z58==1&&z510==1&&z56==1&&z57==1&&z59==1) win_flag1<=1;
	else	if(z62==1&&z63==1&&z61==1&&z64==1&&z60==1||z62==1&&z63==1&&z64==1&&z65==1&&z61==1||z62==1&&z63==1&&z64==1&&z65==1&&z66==1||z63==1&&z64==1&&z65==1&&z66==1&&z67==1||z64==1&&z65==1&&z66==1&&z67==1&&z68==1||z68==1&&z65==1&&z66==1&&z67==1&&z69==1||z68==1&&z610==1&&z66==1&&z67==1&&z69==1) win_flag1<=1;
	else	if(z72==1&&z73==1&&z71==1&&z74==1&&z70==1||z72==1&&z73==1&&z74==1&&z75==1&&z71==1||z72==1&&z73==1&&z74==1&&z75==1&&z76==1||z73==1&&z74==1&&z75==1&&z76==1&&z77==1||z74==1&&z75==1&&z76==1&&z77==1&&z78==1||z78==1&&z75==1&&z76==1&&z77==1&&z79==1||z78==1&&z710==1&&z76==1&&z77==1&&z79==1) win_flag1<=1;	
	else	if(z82==1&&z83==1&&z81==1&&z84==1&&z80==1||z82==1&&z83==1&&z84==1&&z85==1&&z81==1||z82==1&&z83==1&&z84==1&&z85==1&&z86==1||z83==1&&z84==1&&z85==1&&z86==1&&z87==1||z84==1&&z85==1&&z86==1&&z87==1&&z88==1||z88==1&&z85==1&&z86==1&&z87==1&&z89==1||z88==1&&z810==1&&z86==1&&z87==1&&z89==1) win_flag1<=1;
	else	if(z12==1&&z13==1&&z11==1&&z14==1&&z10==1||z12==1&&z13==1&&z14==1&&z15==1&&z11==1||z12==1&&z13==1&&z14==1&&z15==1&&z16==1||z13==1&&z14==1&&z15==1&&z16==1&&z17==1||z14==1&&z15==1&&z06==1&&z07==1&&z08==1||z08==1&&z05==1&&z06==1&&z07==1&&z09==1||z08==1&&z010==1&&z06==1&&z07==1&&z09==1) win_flag1<=1;
	else	if(z02==1&&z03==1&&z01==1&&z04==1&&z00==1||z02==1&&z03==1&&z04==1&&z05==1&&z01==1||z02==1&&z03==1&&z04==1&&z05==1&&z06==1||z03==1&&z04==1&&z05==1&&z06==1&&z07==1||z04==1&&z05==1&&z16==1&&z17==1&&z18==1||z18==1&&z15==1&&z16==1&&z17==1&&z19==1||z18==1&&z110==1&&z16==1&&z17==1&&z19==1) win_flag1<=1;
	else	if(z92==1&&z93==1&&z91==1&&z94==1&&z90==1||z92==1&&z93==1&&z94==1&&z95==1&&z91==1||z92==1&&z93==1&&z94==1&&z95==1&&z96==1||z93==1&&z94==1&&z95==1&&z96==1&&z97==1||z94==1&&z95==1&&z96==1&&z97==1&&z98==1||z98==1&&z95==1&&z96==1&&z97==1&&z99==1||z98==1&&z910==1&&z96==1&&z97==1&&z99==1) win_flag1<=1;
	else	if(z102==1&&z103==1&&z101==1&&z104==1&&z100==1||z102==1&&z103==1&&z104==1&&z105==1&&z101==1||z102==1&&z103==1&&z104==1&&z105==1&&z106==1||103==1&&z104==1&&z105==1&&z106==1&&z107==1||z104==1&&z105==1&&z106==1&&z107==1&&z108==1||z108==1&&z105==1&&z106==1&&z107==1&&z109==1||z108==1&&z1010==1&&z106==1&&z77==1&&z79==1) win_flag1<=1;		
	//////////////////////////////shu huang  wu zi/////////////
	else	if(z00==1&&z10==1&&z20==1&&z30==1&&z40==1||z10==1&&z20==1&&z30==1&&z40==1&&z50==1||z20==1&&z30==1&&z40==1&&z50==1&&z60==1||z30==1&&z40==1&&z50==1&&z60==1&&z70==1||z40==1&&z50==1&&z60==1&&z70==1&&z80==1||z50==1&&z60==1&&z70==1&&z80==1&&z90==1||z60==1&&z70==1&&z80==1&&z90==1&&z100==1) win_flag1<=1;
	else	if(z01==1&&z11==1&&z21==1&&z31==1&&z41==1||z11==1&&z21==1&&z31==1&&z41==1&&z51==1||z21==1&&z31==1&&z41==1&&z51==1&&z61==1||z31==1&&z41==1&&z51==1&&z61==1&&z71==1||z41==1&&z51==1&&z61==1&&z71==1&&z81==1||z51==1&&z61==1&&z71==1&&z81==1&&z91==1||z61==1&&z71==1&&z81==1&&z91==1&&z101==1) win_flag1<=1;
	else	if(z02==1&&z12==1&&z22==1&&z32==1&&z42==1||z12==1&&z22==1&&z32==1&&z42==1&&z52==1||z22==1&&z32==1&&z42==1&&z52==1&&z62==1||z32==1&&z42==1&&z52==1&&z62==1&&z72==1||z42==1&&z52==1&&z62==1&&z72==1&&z82==1||z52==1&&z62==1&&z72==1&&z82==1&&z92==1||z62==1&&z72==1&&z82==1&&z92==1&&z102==1) win_flag1<=1;
	else	if(z03==1&&z13==1&&z23==1&&z33==1&&z43==1||z13==1&&z23==1&&z33==1&&z43==1&&z53==1||z23==1&&z33==1&&z43==1&&z53==1&&z63==1||z33==1&&z43==1&&z53==1&&z63==1&&z73==1||z43==1&&z53==1&&z63==1&&z73==1&&z83==1||z53==1&&z63==1&&z73==1&&z83==1&&z93==1||z63==1&&z73==1&&z83==1&&z93==1&&z103==1) win_flag1<=1;
	else	if(z04==1&&z14==1&&z24==1&&z34==1&&z44==1||z14==1&&z24==1&&z34==1&&z44==1&&z54==1||z24==1&&z34==1&&z44==1&&z54==1&&z64==1||z34==1&&z44==1&&z54==1&&z64==1&&z74==1||z44==1&&z54==1&&z64==1&&z74==1&&z84==1||z54==1&&z64==1&&z74==1&&z84==1&&z94==1||z64==1&&z74==1&&z84==1&&z94==1&&z104==1) win_flag1<=1;
	else	if(z05==1&&z15==1&&z25==1&&z35==1&&z45==1||z15==1&&z25==1&&z35==1&&z45==1&&z55==1||z25==1&&z35==1&&z45==1&&z55==1&&z65==1||z35==1&&z45==1&&z55==1&&z65==1&&z75==1||z45==1&&z55==1&&z65==1&&z75==1&&z85==1||z55==1&&z65==1&&z75==1&&z85==1&&z95==1||z65==1&&z75==1&&z85==1&&z95==1&&z105==1) win_flag1<=1;
	else	if(z06==1&&z16==1&&z26==1&&z36==1&&z46==1||z16==1&&z26==1&&z36==1&&z46==1&&z56==1||z26==1&&z36==1&&z46==1&&z56==1&&z66==1||z36==1&&z46==1&&z56==1&&z66==1&&z76==1||z46==1&&z56==1&&z66==1&&z76==1&&z86==1||z56==1&&z66==1&&z76==1&&z86==1&&z96==1||z66==1&&z76==1&&z86==1&&z96==1&&z106==1) win_flag1<=1;
	else	if(z07==1&&z17==1&&z27==1&&z37==1&&z47==1||z17==1&&z27==1&&z37==1&&z47==1&&z57==1||z27==1&&z37==1&&z47==1&&z57==1&&z67==1||z37==1&&z47==1&&z57==1&&z67==1&&z77==1||z47==1&&z57==1&&z67==1&&z77==1&&z87==1||z57==1&&z67==1&&z77==1&&z87==1&&z97==1||z67==1&&z77==1&&z87==1&&z97==1&&z107==1) win_flag1<=1;
	else	if(z08==1&&z18==1&&z28==1&&z38==1&&z48==1||z18==1&&z28==1&&z38==1&&z48==1&&z58==1||z28==1&&z38==1&&z48==1&&z58==1&&z68==1||z38==1&&z48==1&&z58==1&&z68==1&&z78==1||z48==1&&z58==1&&z68==1&&z78==1&&z88==1||z58==1&&z68==1&&z78==1&&z88==1&&z98==1||z68==1&&z78==1&&z88==1&&z98==1&&z108==1) win_flag1<=1;
	else	if(z09==1&&z19==1&&z29==1&&z39==1&&z49==1||z19==1&&z29==1&&z39==1&&z49==1&&z59==1||z29==1&&z39==1&&z49==1&&z59==1&&z69==1||z39==1&&z49==1&&z59==1&&z69==1&&z79==1||z49==1&&z59==1&&z69==1&&z79==1&&z89==1||z59==1&&z69==1&&z79==1&&z89==1&&z99==1||z69==1&&z79==1&&z89==1&&z99==1&&z109==1) win_flag1<=1;
	else	if(z010==1&&z110==1&&z210==1&&z310==1&&z410==1||z110==1&&z210==1&&z310==1&&z410==1&&z510==1||z210==1&&z310==1&&z410==1&&z510==1&&z610==1||z310==1&&z410==1&&z510==1&&z610==1&&z710==1||z410==1&&z510==1&&z610==1&&z710==1&&z810==1||z510==1&&z610==1&&z710==1&&z810==1&&z910==1||z610==1&&z710==1&&z810==1&&z910==1&&z1010==1) win_flag1<=1;
////////////////////////////////////heng hang wu zi /////////////////////////////
	else	if(v22==1&&v23==1&&v21==1&&v24==1&&v20==1||v22==1&&v23==1&&v24==1&&v25==1&&v21==1||v22==1&&v23==1&&v24==1&&v25==1&&v26==1||v23==1&&v24==1&&v25==1&&v26==1&&v27==1||v24==1&&v25==1&&v26==1&&v27==1&&v28==1||v28==1&&v25==1&&v26==1&&v27==1&&v29==1||v28==1&&v210==1&&v26==1&&v27==1&&v29==1) win_flag<=1;
	else	if(v32==1&&v33==1&&v31==1&&v34==1&&v30==1||v32==1&&v33==1&&v34==1&&v35==1&&v31==1||v32==1&&v33==1&&v34==1&&v35==1&&v36==1||v33==1&&v34==1&&v35==1&&v36==1&&v37==1||v34==1&&v35==1&&v36==1&&v37==1&&v38==1||v38==1&&v35==1&&v36==1&&v37==1&&v39==1||v38==1&&v310==1&&v36==1&&v37==1&&v39==1) win_flag<=1;
	else	if(v42==1&&v43==1&&v41==1&&v44==1&&v40==1||v42==1&&v43==1&&v44==1&&v45==1&&v41==1||v42==1&&v43==1&&v44==1&&v45==1&&v46==1||v43==1&&v44==1&&v45==1&&v46==1&&v47==1||v44==1&&v45==1&&v46==1&&v47==1&&v48==1||v48==1&&v45==1&&v46==1&&v47==1&&v49==1||v48==1&&v410==1&&v46==1&&v47==1&&v49==1) win_flag<=1;
	else	if(v52==1&&v53==1&&v51==1&&v54==1&&v50==1||v52==1&&v53==1&&v54==1&&v55==1&&v51==1||v52==1&&v53==1&&v54==1&&v55==1&&v56==1||v53==1&&v54==1&&v55==1&&v56==1&&v57==1||v54==1&&v55==1&&v56==1&&v57==1&&v58==1||v58==1&&v55==1&&v56==1&&v57==1&&v59==1||v58==1&&v510==1&&v56==1&&v57==1&&v59==1) win_flag<=1;
	else	if(v62==1&&v63==1&&v61==1&&v64==1&&v60==1||v62==1&&v63==1&&v64==1&&v65==1&&v61==1||v62==1&&v63==1&&v64==1&&v65==1&&v66==1||v63==1&&v64==1&&v65==1&&v66==1&&v67==1||v64==1&&v65==1&&v66==1&&v67==1&&v68==1||v68==1&&v65==1&&v66==1&&v67==1&&v69==1||v68==1&&v610==1&&v66==1&&v67==1&&v69==1) win_flag<=1;
	else	if(v72==1&&v73==1&&v71==1&&v74==1&&v70==1||v72==1&&v73==1&&v74==1&&v75==1&&v71==1||v72==1&&v73==1&&v74==1&&v75==1&&v76==1||v73==1&&v74==1&&v75==1&&v76==1&&v77==1||v74==1&&v75==1&&v76==1&&v77==1&&v78==1||v78==1&&v75==1&&v76==1&&v77==1&&v79==1||v78==1&&v710==1&&v76==1&&v77==1&&v79==1) win_flag<=1;	
	else	if(v82==1&&v83==1&&v81==1&&v84==1&&v80==1||v82==1&&v83==1&&v84==1&&v85==1&&v81==1||v82==1&&v83==1&&v84==1&&v85==1&&v86==1||v83==1&&v84==1&&v85==1&&v86==1&&v87==1||v84==1&&v85==1&&v86==1&&v87==1&&v88==1||v88==1&&v85==1&&v86==1&&v87==1&&v89==1||v88==1&&v810==1&&v86==1&&v87==1&&v89==1) win_flag<=1;
	else	if(v12==1&&v13==1&&v11==1&&v14==1&&v10==1||v12==1&&v13==1&&v14==1&&v15==1&&v11==1||v12==1&&v13==1&&v14==1&&v15==1&&v16==1||v13==1&&v14==1&&v15==1&&v16==1&&v17==1||v14==1&&v15==1&&v06==1&&v07==1&&v08==1||v08==1&&v05==1&&v06==1&&v07==1&&v09==1||v08==1&&v010==1&&v06==1&&v07==1&&v09==1) win_flag<=1;
	else	if(v02==1&&v03==1&&v01==1&&v04==1&&v00==1||v02==1&&v03==1&&v04==1&&v05==1&&v01==1||v02==1&&v03==1&&v04==1&&v05==1&&v06==1||v03==1&&v04==1&&v05==1&&v06==1&&v07==1||v04==1&&v05==1&&v16==1&&v17==1&&v18==1||v18==1&&v15==1&&v16==1&&v17==1&&v19==1||v18==1&&v110==1&&v16==1&&v17==1&&v19==1) win_flag<=1;
	else	if(v92==1&&v93==1&&v91==1&&v94==1&&v90==1||v92==1&&v93==1&&v94==1&&v95==1&&v91==1||v92==1&&v93==1&&v94==1&&v95==1&&v96==1||v93==1&&v94==1&&v95==1&&v96==1&&v97==1||v94==1&&v95==1&&v96==1&&v97==1&&v98==1||v98==1&&v95==1&&v96==1&&v97==1&&v99==1||v98==1&&v910==1&&v96==1&&v97==1&&v99==1) win_flag<=1;
	else	if(v102==1&&v103==1&&v101==1&&v104==1&&v100==1||v102==1&&v103==1&&v104==1&&v105==1&&v101==1||v102==1&&v103==1&&v104==1&&v105==1&&v106==1||v103==1&&v104==1&&v105==1&&v106==1&&v107==1||v104==1&&v105==1&&v106==1&&v107==1&&v108==1||v108==1&&v105==1&&v106==1&&v107==1&&v109==1||v108==1&&v1010==1&&v106==1&&v77==1&&v79==1) win_flag<=1;		
//////////////////////////////////////shu huang  wu zi/////////////
	else	if(v00==1&&v10==1&&v20==1&&v30==1&&v40==1||v10==1&&v20==1&&v30==1&&v40==1&&v50==1||v20==1&&v30==1&&v40==1&&v50==1&&v60==1||v30==1&&v40==1&&v50==1&&v60==1&&v70==1||v40==1&&v50==1&&v60==1&&v70==1&&v80==1||v50==1&&v60==1&&v70==1&&v80==1&&v90==1||v60==1&&v70==1&&v80==1&&v90==1&&v100==1) win_flag<=1;
	else	if(v01==1&&v11==1&&v21==1&&v31==1&&v41==1||v11==1&&v21==1&&v31==1&&v41==1&&v51==1||v21==1&&v31==1&&v41==1&&v51==1&&v61==1||v31==1&&v41==1&&v51==1&&v61==1&&v71==1||v41==1&&v51==1&&v61==1&&v71==1&&v81==1||v51==1&&v61==1&&v71==1&&v81==1&&v91==1||v61==1&&v71==1&&v81==1&&v91==1&&v101==1) win_flag<=1;
	else	if(v02==1&&v12==1&&v22==1&&v32==1&&v42==1||v12==1&&v22==1&&v32==1&&v42==1&&v52==1||v22==1&&v32==1&&v42==1&&v52==1&&v62==1||v32==1&&v42==1&&v52==1&&v62==1&&v72==1||v42==1&&v52==1&&v62==1&&v72==1&&v82==1||v52==1&&v62==1&&v72==1&&v82==1&&v92==1||v62==1&&v72==1&&v82==1&&v92==1&&v102==1) win_flag<=1;
	else	if(v03==1&&v13==1&&v23==1&&v33==1&&v43==1||v13==1&&v23==1&&v33==1&&v43==1&&v53==1||v23==1&&v33==1&&v43==1&&v53==1&&v63==1||v33==1&&v43==1&&v53==1&&v63==1&&v73==1||v43==1&&v53==1&&v63==1&&v73==1&&v83==1||v53==1&&v63==1&&v73==1&&v83==1&&v93==1||v63==1&&v73==1&&v83==1&&v93==1&&v103==1) win_flag<=1;
	else	if(v04==1&&v14==1&&v24==1&&v34==1&&v44==1||v14==1&&v24==1&&v34==1&&v44==1&&v54==1||v24==1&&v34==1&&v44==1&&v54==1&&v64==1||v34==1&&v44==1&&v54==1&&v64==1&&v74==1||v44==1&&v54==1&&v64==1&&v74==1&&v84==1||v54==1&&v64==1&&v74==1&&v84==1&&v94==1||v64==1&&v74==1&&v84==1&&v94==1&&v104==1) win_flag<=1;
	else	if(v05==1&&v15==1&&v25==1&&v35==1&&v45==1||v15==1&&v25==1&&v35==1&&v45==1&&v55==1||v25==1&&v35==1&&v45==1&&v55==1&&v65==1||v35==1&&v45==1&&v55==1&&v65==1&&v75==1||v45==1&&v55==1&&v65==1&&v75==1&&v85==1||v55==1&&v65==1&&v75==1&&v85==1&&v95==1||v65==1&&v75==1&&v85==1&&v95==1&&v105==1) win_flag<=1;
	else	if(v06==1&&v16==1&&v26==1&&v36==1&&v46==1||v16==1&&v26==1&&v36==1&&v46==1&&v56==1||v26==1&&v36==1&&v46==1&&v56==1&&v66==1||v36==1&&v46==1&&v56==1&&v66==1&&v76==1||v46==1&&v56==1&&v66==1&&v76==1&&v86==1||v56==1&&v66==1&&v76==1&&v86==1&&v96==1||v66==1&&v76==1&&v86==1&&v96==1&&v106==1) win_flag<=1;
	else	if(v07==1&&v17==1&&v27==1&&v37==1&&v47==1||v17==1&&v27==1&&v37==1&&v47==1&&v57==1||v27==1&&v37==1&&v47==1&&v57==1&&v67==1||v37==1&&v47==1&&v57==1&&v67==1&&v77==1||v47==1&&v57==1&&v67==1&&v77==1&&v87==1||v57==1&&v67==1&&v77==1&&v87==1&&v97==1||v67==1&&v77==1&&v87==1&&v97==1&&v107==1) win_flag<=1;
	else	if(v08==1&&v18==1&&v28==1&&v38==1&&v48==1||v18==1&&v28==1&&v38==1&&v48==1&&v58==1||v28==1&&v38==1&&v48==1&&v58==1&&v68==1||v38==1&&v48==1&&v58==1&&v68==1&&v78==1||v48==1&&v58==1&&v68==1&&v78==1&&v88==1||v58==1&&v68==1&&v78==1&&v88==1&&v98==1||v68==1&&v78==1&&v88==1&&v98==1&&v108==1) win_flag<=1;
	else	if(v09==1&&v19==1&&v29==1&&v39==1&&v49==1||v19==1&&v29==1&&v39==1&&v49==1&&v59==1||v29==1&&v39==1&&v49==1&&v59==1&&v69==1||v39==1&&v49==1&&v59==1&&v69==1&&v79==1||v49==1&&v59==1&&v69==1&&v79==1&&v89==1||v59==1&&v69==1&&v79==1&&v89==1&&v99==1||v69==1&&v79==1&&v89==1&&v99==1&&v109==1) win_flag<=1;
	else	if(v010==1&&v110==1&&v210==1&&v310==1&&v410==1||v110==1&&v210==1&&v310==1&&v410==1&&v510==1||v210==1&&v310==1&&v410==1&&v510==1&&v610==1||v310==1&&v410==1&&v510==1&&v610==1&&v710==1||v410==1&&v510==1&&v610==1&&v710==1&&v810==1||v510==1&&v610==1&&v710==1&&v810==1&&v910==1||v610==1&&v710==1&&v810==1&&v910==1&&v1010==1) win_flag<=1;
////////////////////////////////////heng hang wu zi ////////////////////////////////////////////////////////////////////////////
    else	if(z00==1&&z11==1&&z22==1&&z33==1&&z44==1||z11==1&&z22==1&&z33==1&&z44==1&&z55==1||z22==1&&z33==1&&z44==1&&z55==1&&z66==1||z33==1&&z44==1&&z55==1&&z66==1&&z77==1||z44==1&&z55==1&&z66==1&&z77==1&&z88==1||z55==1&&z66==1&&z77==1&&z88==1&&z99==1||z66==1&&z77==1&&z88==1&&z99==1&&z1010==1) win_flag1<=1;	
    
    else	if(z01==1&&z12==1&&z23==1&&z34==1&&z45==1||z12==1&&z23==1&&z34==1&&z45==1&&z56==1||z23==1&&z34==1&&z45==1&&z56==1&&z67==1||z34==1&&z45==1&&z56==1&&z67==1&&z78==1||z45==1&&z56==1&&z67==1&&z78==1&&z89==1||z56==1&&z67==1&&z78==1&&z89==1&&z910==1) win_flag1<=1;	
    else	if(z02==1&&z13==1&&z24==1&&z35==1&&z46==1||z13==1&&z24==1&&z35==1&&z46==1&&z57==1||z24==1&&z35==1&&z46==1&&z57==1&&z68==1||z35==1&&z46==1&&z57==1&&z68==1&&z79==1||z46==1&&z57==1&&z68==1&&z79==1&&z810==1) win_flag1<=1;	
    else	if(z03==1&&z14==1&&z25==1&&z36==1&&z47==1||z14==1&&z25==1&&z36==1&&z47==1&&z58==1||z25==1&&z36==1&&z47==1&&z58==1&&z69==1||z36==1&&z47==1&&z58==1&&z69==1&&z710==1) win_flag1<=1;	
    else	if(z04==1&&z15==1&&z26==1&&z37==1&&z48==1||z15==1&&z26==1&&z37==1&&z48==1&&z59==1||z26==1&&z37==1&&z48==1&&z59==1&&z610==1) win_flag1<=1;	
    else	if(z05==1&&z16==1&&z27==1&&z38==1&&z49==1||z16==1&&z27==1&&z38==1&&z49==1&&z510==1) win_flag1<=1;	
    else	if(z06==1&&z17==1&&z28==1&&z39==1&&z410==1) win_flag1<=1;
    	
    else	if(z10==1&&z21==1&&z32==1&&z43==1&&z54==1||z21==1&&z32==1&&z43==1&&z54==1&&z65==1||z32==1&&z43==1&&z54==1&&z65==1&&z76==1||z43==1&&z54==1&&z65==1&&z76==1&&z87==1||z54==1&&z65==1&&z67==1&&z87==1&&z98==1||z65==1&&z76==1&&z87==1&&z98==1&&z109==1) win_flag1<=1;	
    else	if(z20==1&&z31==1&&z42==1&&z53==1&&z64==1||z31==1&&z42==1&&z53==1&&z64==1&&z75==1||z42==1&&z53==1&&z64==1&&z75==1&&z86==1||z53==1&&z64==1&&z75==1&&z86==1&&z97==1||z64==1&&z75==1&&z86==1&&z97==1&&z108==1) win_flag1<=1;	
    else	if(z30==1&&z41==1&&z52==1&&z63==1&&z74==1||z41==1&&z52==1&&z63==1&&z74==1&&z85==1||z52==1&&z63==1&&z74==1&&z85==1&&z96==1||z63==1&&z74==1&&z85==1&&z96==1&&z107==1) win_flag1<=1;	
    else	if(z40==1&&z51==1&&z62==1&&z73==1&&z84==1||z51==1&&z62==1&&z73==1&&z84==1&&z95==1||z62==1&&z73==1&&z84==1&&z95==1&&z106==1) win_flag1<=1;	
    else	if(z50==1&&z61==1&&z72==1&&z83==1&&z94==1||z61==1&&z72==1&&z83==1&&z94==1&&z105==1) win_flag1<=1;	
    else	if(z60==1&&z71==1&&z82==1&&z93==1&&z104==1) win_flag1<=1;	
///////////////////////////////////////////////you xie///////////////////////////////////////////////////////////////////////////		
    else	if(v00==1&&v11==1&&v22==1&&v33==1&&v44==1||v11==1&&v22==1&&v33==1&&v44==1&&v55==1||v22==1&&v33==1&&v44==1&&v55==1&&v66==1||v33==1&&v44==1&&v55==1&&v66==1&&v77==1||v44==1&&v55==1&&v66==1&&v77==1&&v88==1||v55==1&&v66==1&&v77==1&&v88==1&&v99==1||v66==1&&v77==1&&v88==1&&v99==1&&v1010==1) win_flag<=1;	
    
    else	if(v01==1&&v12==1&&v23==1&&v34==1&&v45==1||v12==1&&v23==1&&v34==1&&v45==1&&v56==1||v23==1&&v34==1&&v45==1&&v56==1&&v67==1||v34==1&&v45==1&&v56==1&&v67==1&&v78==1||v45==1&&v56==1&&v67==1&&z78==1&&v89==1||v56==1&&v67==1&&v78==1&&v89==1&&v910==1) win_flag<=1;	
    else	if(v02==1&&v13==1&&v24==1&&v35==1&&v46==1||v13==1&&v24==1&&v35==1&&v46==1&&v57==1||v24==1&&v35==1&&v46==1&&v57==1&&v68==1||v35==1&&v46==1&&v57==1&&v68==1&&v79==1||v46==1&&v57==1&&v68==1&&z79==1&&v810==1) win_flag<=1;	
    else	if(v03==1&&v14==1&&v25==1&&v36==1&&v47==1||v14==1&&v25==1&&v36==1&&v47==1&&v58==1||v25==1&&v36==1&&v47==1&&v58==1&&v69==1||v36==1&&v47==1&&v58==1&&v69==1&&v710==1) win_flag<=1;	
    else	if(v04==1&&v15==1&&v26==1&&v37==1&&v48==1||v15==1&&v26==1&&v37==1&&v48==1&&v59==1||v26==1&&v37==1&&v48==1&&v59==1&&v610==1) win_flag<=1;	
    else	if(v05==1&&v16==1&&v27==1&&v38==1&&v49==1||v16==1&&v27==1&&v38==1&&v49==1&&v510==1) win_flag<=1;	
    else	if(v06==1&&v17==1&&v28==1&&v39==1&&v410==1) win_flag<=1;
    	
    else	if(v10==1&&v21==1&&v32==1&&v43==1&&v54==1||v21==1&&v32==1&&v43==1&&v54==1&&v65==1||v32==1&&v43==1&&v54==1&&v65==1&&v76==1||v43==1&&v54==1&&v65==1&&v76==1&&v87==1||v54==1&&v65==1&&v67==1&&v87==1&&v98==1||v65==1&&v76==1&&v87==1&&v98==1&&v109==1) win_flag<=1;	
    else	if(v20==1&&v31==1&&v42==1&&v53==1&&v64==1||v31==1&&v42==1&&v53==1&&v64==1&&v75==1||v42==1&&v53==1&&v64==1&&v75==1&&v86==1||v53==1&&v64==1&&v75==1&&v86==1&&v97==1||v64==1&&v75==1&&v86==1&&v97==1&&v108==1) win_flag<=1;	
    else	if(v30==1&&v41==1&&v52==1&&v63==1&&v74==1||v41==1&&v52==1&&v63==1&&v74==1&&v85==1||v52==1&&v63==1&&v74==1&&v85==1&&v96==1||v63==1&&v74==1&&v85==1&&v96==1&&v107==1) win_flag<=1;	
    else	if(v40==1&&v51==1&&v62==1&&v73==1&&v84==1||v51==1&&v62==1&&v73==1&&v84==1&&v95==1||v62==1&&v73==1&&v84==1&&v95==1&&v106==1) win_flag<=1;	
    else	if(v50==1&&v61==1&&v72==1&&v83==1&&v94==1||v61==1&&v72==1&&v83==1&&v94==1&&v105==1) win_flag<=1;	
    else	if(v60==1&&v71==1&&v82==1&&v93==1&&v104==1) win_flag<=1;	
///////////////////////////////////////////////you xie///////////////////////////////////////////////////////////////////////////	
    else	if(v010==1&&v19==1&&v28==1&&v37==1&&v46==1||v19==1&&v28==1&&v37==1&&v46==1&&v55==1||v28==1&&v37==1&&v46==1&&v55==1&&v64==1||v37==1&&v46==1&&v55==1&&v64==1&&v73==1||v46==1&&v55==1&&v64==1&&v73==1&&v82==1||v55==1&&v64==1&&v73==1&&v82==1&&v91==1||v64==1&&v73==1&&v82==1&&v91==1&&v100==1) win_flag<=1;					
    
    else	if(v09==1&&v18==1&&v27==1&&v36==1&&v45==1||v18==1&&v27==1&&v36==1&&v45==1&&v54==1||v27==1&&v36==1&&v45==1&&v54==1&&v63==1||v36==1&&v45==1&&v54==1&&v63==1&&v72==1||v45==1&&v54==1&&v63==1&&z72==1&&v81==1||v54==1&&v63==1&&v72==1&&v81==1&&v90==1) win_flag<=1;	
    else	if(v08==1&&v17==1&&v26==1&&v35==1&&v44==1||v17==1&&v26==1&&v35==1&&v44==1&&v53==1||v26==1&&v35==1&&v44==1&&v53==1&&v62==1||v35==1&&v44==1&&v53==1&&v62==1&&v71==1||v44==1&&v53==1&&v62==1&&z71==1&&v80==1) win_flag<=1;	
    else	if(v07==1&&v16==1&&v25==1&&v34==1&&v43==1||v16==1&&v25==1&&v34==1&&v43==1&&v52==1||v25==1&&v34==1&&v43==1&&v52==1&&v61==1||v34==1&&v43==1&&v52==1&&v61==1&&v70==1) win_flag<=1;	
    else	if(v06==1&&v15==1&&v24==1&&v33==1&&v42==1||v15==1&&v24==1&&v33==1&&v42==1&&v51==1||v24==1&&v33==1&&v42==1&&v51==1&&v60==1) win_flag<=1;	
    else	if(v05==1&&v14==1&&v23==1&&v32==1&&v41==1||v14==1&&v23==1&&v32==1&&v41==1&&v50==1) win_flag<=1;	
    else	if(v04==1&&v13==1&&v22==1&&v31==1&&v40==1) win_flag<=1;
    
    else	if(v101==1&&v92==1&&v83==1&&v74==1&&v65==1||v92==1&&v83==1&&v74==1&&v65==1&&v56==1||v83==1&&v74==1&&v65==1&&v56==1&&v47==1||v74==1&&v65==1&&v56==1&&v47==1&&v38==1||v65==1&&v56==1&&v47==1&&z38==1&&v29==1||v56==1&&v47==1&&v38==1&&v29==1&&v110==1) win_flag<=1;	
    else	if(v102==1&&v93==1&&v84==1&&v75==1&&v66==1||v93==1&&v84==1&&v75==1&&v66==1&&v57==1||v84==1&&v75==1&&v66==1&&v57==1&&v48==1||v75==1&&v66==1&&v57==1&&v48==1&&v39==1||v66==1&&v57==1&&v48==1&&z39==1&&v210==1) win_flag<=1;	
    else	if(v103==1&&v94==1&&v85==1&&v76==1&&v67==1||v94==1&&v85==1&&v76==1&&v67==1&&v58==1||v85==1&&v76==1&&v67==1&&v58==1&&v49==1||v76==1&&v67==1&&v58==1&&v49==1&&v310==1) win_flag<=1;	
    else	if(v104==1&&v95==1&&v86==1&&v77==1&&v68==1||v95==1&&v86==1&&v77==1&&v68==1&&v59==1||v86==1&&v77==1&&v68==1&&v59==1&&v410==1) win_flag<=1;	
    else	if(v105==1&&v96==1&&v87==1&&v78==1&&v69==1||v96==1&&v87==1&&v78==1&&v69==1&&v510==1) win_flag<=1;	
    else	if(v106==1&&v97==1&&v88==1&&v79==1&&v610==1) win_flag<=1;
///////////////////////////////////////////////////////////zuo xie///////////////////////////////////////////////////////////////////////////////////////////////////
    else	if(z010==1&&z19==1&&z28==1&&z37==1&&z46==1||z19==1&&z28==1&&z37==1&&z46==1&&z55==1||z28==1&&z37==1&&z46==1&&z55==1&&z64==1||z37==1&&z46==1&&z55==1&&z64==1&&z73==1||z46==1&&z55==1&&z64==1&&z73==1&&z82==1||z55==1&&z64==1&&z73==1&&z82==1&&z91==1||z64==1&&z73==1&&z82==1&&z91==1&&z100==1) win_flag1<=1;					
    
    else	if(z09==1&&z18==1&&z27==1&&z36==1&&z45==1||z18==1&&z27==1&&z36==1&&z45==1&&z54==1||z27==1&&z36==1&&z45==1&&z54==1&&z63==1||z36==1&&z45==1&&z54==1&&z63==1&&z72==1||z45==1&&z54==1&&z63==1&&z72==1&&z81==1||z54==1&&z63==1&&z72==1&&z81==1&&z90==1) win_flag1<=1;	
    else	if(z08==1&&z17==1&&z26==1&&z35==1&&z44==1||z17==1&&z26==1&&z35==1&&z44==1&&z53==1||z26==1&&z35==1&&z44==1&&z53==1&&z62==1||z35==1&&z44==1&&z53==1&&z62==1&&z71==1||z44==1&&z53==1&&z62==1&&z71==1&&z80==1) win_flag1<=1;	
    else	if(z07==1&&z16==1&&z25==1&&z34==1&&z43==1||z16==1&&z25==1&&z34==1&&z43==1&&z52==1||z25==1&&z34==1&&z43==1&&z52==1&&z61==1||z34==1&&z43==1&&z52==1&&z61==1&&z70==1) win_flag1<=1;	
    else	if(z06==1&&z15==1&&z24==1&&z33==1&&z42==1||z15==1&&z24==1&&z33==1&&z42==1&&z51==1||z24==1&&z33==1&&z42==1&&z51==1&&z60==1) win_flag1<=1;	
    else	if(z05==1&&z14==1&&z23==1&&z32==1&&z41==1||z14==1&&z23==1&&z32==1&&z41==1&&z50==1) win_flag1<=1;	
    else	if(z04==1&&z13==1&&z22==1&&z31==1&&z40==1) win_flag1<=1;
     
    else	if(z101==1&&z92==1&&z83==1&&z74==1&&z65==1||z92==1&&z83==1&&z74==1&&z65==1&&z56==1||z83==1&&z74==1&&z65==1&&z56==1&&z47==1||z74==1&&z65==1&&z56==1&&z47==1&&z38==1||z65==1&&z56==1&&z47==1&&z38==1&&z29==1||z56==1&&z47==1&&z38==1&&z29==1&&z110==1) win_flag1<=1;	
    else	if(z102==1&&z93==1&&z84==1&&z75==1&&z66==1||z93==1&&z84==1&&z75==1&&z66==1&&z57==1||z84==1&&z75==1&&z66==1&&z57==1&&z48==1||z75==1&&z66==1&&z57==1&&z48==1&&z39==1||z66==1&&z57==1&&z48==1&&z39==1&&z210==1) win_flag1<=1;	
    else	if(z103==1&&z94==1&&z85==1&&z76==1&&z67==1||z94==1&&z85==1&&z76==1&&z67==1&&z58==1||z85==1&&z76==1&&z67==1&&z58==1&&z49==1||z76==1&&z67==1&&z58==1&&z49==1&&z310==1) win_flag1<=1;	
    else	if(z104==1&&z95==1&&z86==1&&z77==1&&z68==1||z95==1&&z86==1&&z77==1&&z68==1&&z59==1||z86==1&&z77==1&&z68==1&&z59==1&&z410==1) win_flag1<=1;	
    else	if(z105==1&&z96==1&&z87==1&&z78==1&&z69==1||z96==1&&z87==1&&z78==1&&z69==1&&z510==1) win_flag1<=1;	
    else	if(z106==1&&z97==1&&z88==1&&z79==1&&z610==1) win_flag1<=1;
///////////////////////////////////////////////////////////zuo xie/////////////////////////////////////////////////////////////////////////////////		
		else win_flag<=0;
    end
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
always@(posedge CLK,negedge rst)
	begin
		if(!rst) ting_flag<=1;
		else if(win_flag==1||win_flag1==1) ting_flag<=0;
			else ting_flag<=1;
	end
always@(posedge CLK,negedge rst)
	if(!rst)
	begin
				x=160;
				y=240;
				num=0;
		z00=0;z01=0;z02=0;z03=0;z04=0;z05=0;z06=0;z07=0;z08=0;z09=0;z010=0;
		z10=0;z11=0;z12=0;z13=0;z14=0;z15=0;z16=0;z17=0;z18=0;z19=0;z110=0;
        z20=0;z21=0;z22=0;z23=0;z24=0;z25=0;z26=0;z27=0;z28=0;z29=0;z210=0;
        z30=0;z31=0;z32=0;z33=0;z34=0;z35=0;z36=0;z37=0;z38=0;z39=0;z310=0;
        z40=0;z41=0;z42=0;z43=0;z44=0;z45=0;z46=0;z47=0;z48=0;z49=0;z410=0;
        z50=0;z51=0;z52=0;z53=0;z54=0;z55=0;z56=0;z57=0;z58=0;z59=0;z510=0;
        z60=0;z61=0;z62=0;z63=0;z64=0;z65=0;z66=0;z67=0;z68=0;z69=0;z610=0;
        z70=0;z71=0;z72=0;z73=0;z74=0;z75=0;z76=0;z77=0;z78=0;z79=0;z710=0;
        z80=0;z81=0;z82=0;z83=0;z84=0;z85=0;z86=0;z87=0;z88=0;z89=0;z810=0;
        z90=0;z91=0;z92=0;z93=0;z94=0;z95=0;z96=0;z97=0;z98=0;z99=0;z910=0;
        z100=0;z101=0;z102=0;z103=0;z104=0;z105=0;z106=0;z107=0;z108=0;z109=0;z1010=0;//hei qi biao zhi wei
	    v00=0;v01=0;v02=0;v03=0;v04=0;v05=0;v06=0;v07=0;v08=0;v09=0;v010=0;
		v10=0;v11=0;v12=0;v13=0;v14=0;v15=0;v16=0;v17=0;v18=0;v19=0;v110=0;
        v20=0;v21=0;v22=0;v23=0;v24=0;v25=0;v26=0;v27=0;v28=0;v29=0;v210=0;
        v30=0;v31=0;v32=0;v33=0;v34=0;v35=0;v36=0;v37=0;v38=0;v39=0;v310=0;
        v40=0;v41=0;v42=0;v43=0;v44=0;v45=0;v46=0;v47=0;v48=0;v49=0;v410=0;
        v50=0;v51=0;v52=0;v53=0;v54=0;v55=0;v56=0;v57=0;v58=0;v59=0;v510=0;
        v60=0;v61=0;v62=0;v63=0;v64=0;v65=0;v66=0;v67=0;v68=0;v69=0;v610=0;
        v70=0;v71=0;v72=0;v73=0;v74=0;v75=0;v76=0;v77=0;v78=0;v79=0;v710=0;
        v80=0;v81=0;v82=0;v83=0;v84=0;v85=0;v86=0;v87=0;v88=0;v89=0;v810=0;
        v90=0;v91=0;v92=0;v93=0;v94=0;v95=0;v96=0;v97=0;v98=0;v99=0;v910=0;
		v100=0;v101=0;v102=0;v103=0;v104=0;v105=0;v106=0;v107=0;v108=0;v109=0;v1010=0;//hong qi biao zhi wei 

      end
    else  
	begin
           case(key_signal)  
            8'h44 : begin x<=x+30;key_flag<=0;         if(x>310) 	  x<=10; end
            8'h41 : begin x<=x-30;key_flag<=0;         if(x<10)       x<=310;end
            8'h53 : begin y<=y+30;key_flag<=0;         if(y>390)      y<=90;end
            8'h02 : begin y<=y-30;key_flag<=0;         if(y<90)       y<=390;end
            8'h55 : begin 
						key_flag<=1;
						num<=num+1;
						if(x==10)  
							begin
								if(y==90)
									if(num%2==1) z00=1;else v00=1;	
								if(y==120)
									if(num%2==1) z01=1;else v01=1;
								if(y==150)
									if(num%2==1) z02=1;else v02=1;
								if(y==180)
									if(num%2==1) z03=1;else v03=1;
								if(y==210)
									if(num%2==1) z04=1;else v04=1;
								if(y==240)
									if(num%2==1) z05=1;else v05=1;
								if(y==270)
									if(num%2==1) z06=1;else v06=1;
								if(y==300)
									if(num%2==1) z07=1;else v07=1;;
								if(y==330)
									if(num%2==1) z08=1;else v08=1;
								if(y==360)
									if(num%2==1) z09=1;else v09=1;
								if(y==390)
									if(num%2==1) z010=1;else v010=1;///1111111111111111111111
							end	
						if(x==40)  
							begin
								if(y==90)
									if(num%2==1) z10=1;else v10=1;	
								if(y==120)
									if(num%2==1) z11=1;else v11=1;
								if(y==150)
									if(num%2==1) z12=1;else v12=1;
								if(y==180)
									if(num%2==1) z13=1;else v13=1;
								if(y==210)
									if(num%2==1) z14=1;else v14=1;
								if(y==240)
									if(num%2==1) z15=1;else v15=1;
								if(y==270)
									if(num%2==1) z16=1;else v16=1;
								if(y==300)
									if(num%2==1) z17=1;else v17=1;;
								if(y==330)
									if(num%2==1) z18=1;else v18=1;
								if(y==360)
									if(num%2==1) z19=1;else v19=1;
								if(y==390)
									if(num%2==1) z110=1;else v110=1;//222222222222222222222222222
							end		
						if(x==70)  
							begin
								if(y==90)
									if(num%2==1) z20=1;else v20=1;	
								if(y==120)
									if(num%2==1) z21=1;else v21=1;
								if(y==150)
									if(num%2==1) z22=1;else v22=1;
								if(y==180)
									if(num%2==1) z23=1;else v23=1;
								if(y==210)
									if(num%2==1) z24=1;else v24=1;
								if(y==240)
									if(num%2==1) z25=1;else v25=1;
								if(y==270)
									if(num%2==1) z26=1;else v26=1;
								if(y==300)
									if(num%2==1) z27=1;else v27=1;;
								if(y==330)
									if(num%2==1) z28=1;else v28=1;
								if(y==360)
									if(num%2==1) z29=1;else v29=1;
								if(y==390)
									if(num%2==1) z210=1;else v210=1;//3333333333333333333333333333
							end								

						if(x==100)  
							begin
								if(y==90)
									if(num%2==1) z30=1;else v30=1;	
								if(y==120)
									if(num%2==1) z31=1;else v31=1;
								if(y==150)
									if(num%2==1) z32=1;else v32=1;
								if(y==180)
									if(num%2==1) z33=1;else v33=1;
								if(y==210)
									if(num%2==1) z34=1;else v34=1;
								if(y==240)
									if(num%2==1) z35=1;else v35=1;
								if(y==270)
									if(num%2==1) z36=1;else v36=1;
								if(y==300)
									if(num%2==1) z37=1;else v37=1;;
								if(y==330)
									if(num%2==1) z38=1;else v38=1;
								if(y==360)
									if(num%2==1) z39=1;else v39=1;
								if(y==390)
									if(num%2==1) z310=1;else v310=1;//4444444444444444444444444444444
							end	
						if(x==130)  
							begin
								if(y==90)
									if(num%2==1) z40=1;else v40=1;	
								if(y==120)
									if(num%2==1) z41=1;else v41=1;
								if(y==150)
									if(num%2==1) z42=1;else v42=1;
								if(y==180)
									if(num%2==1) z43=1;else v43=1;
								if(y==210)
									if(num%2==1) z44=1;else v44=1;
								if(y==240)
									if(num%2==1) z45=1;else v45=1;
								if(y==270)
									if(num%2==1) z46=1;else v46=1;
								if(y==300)
									if(num%2==1) z47=1;else v47=1;;
								if(y==330)
									if(num%2==1) z48=1;else v48=1;
								if(y==360)
									if(num%2==1) z49=1;else v49=1;
								if(y==390)
									if(num%2==1) z410=1;else v410=1;//555555555555555555555555555
							end								
						if(x==160)  
							begin
								if(y==90)
									if(num%2==1) z50=1;else v50=1;	
								if(y==120)
									if(num%2==1) z51=1;else v51=1;
								if(y==150)
									if(num%2==1) z52=1;else v52=1;
								if(y==180)
									if(num%2==1) z53=1;else v53=1;
								if(y==210)
									if(num%2==1) z54=1;else v54=1;
								if(y==240)
									if(num%2==1) z55=1;else v55=1;
								if(y==270)
									if(num%2==1) z56=1;else v56=1;
								if(y==300)
									if(num%2==1) z57=1;else v57=1;;
								if(y==330)
									if(num%2==1) z58=1;else v58=1;
								if(y==360)
									if(num%2==1) z59=1;else v59=1;
								if(y==390)
									if(num%2==1) z510=1;else v510=1;//66666666666666666666666666
							end	
						if(x==190)  
							begin
								if(y==90)
									if(num%2==1) z60=1;else v60=1;	
								if(y==120)
									if(num%2==1) z61=1;else v61=1;
								if(y==150)
									if(num%2==1) z62=1;else v62=1;
								if(y==180)
									if(num%2==1) z63=1;else v63=1;
								if(y==210)
									if(num%2==1) z64=1;else v64=1;
								if(y==240)
									if(num%2==1) z65=1;else v65=1;
								if(y==270)
									if(num%2==1) z66=1;else v66=1;
								if(y==300)
									if(num%2==1) z67=1;else v67=1;;
								if(y==330)
									if(num%2==1) z68=1;else v68=1;
								if(y==360)
									if(num%2==1) z69=1;else v69=1;
								if(y==390)
									if(num%2==1) z610=1;else v610=1;//7777777777777777777777777777777
							end		
						if(x==220)  
							begin
								if(y==90)
									if(num%2==1) z70=1;else v70=1;	
								if(y==120)
									if(num%2==1) z71=1;else v71=1;
								if(y==150)
									if(num%2==1) z72=1;else v72=1;
								if(y==180)
									if(num%2==1) z73=1;else v73=1;
								if(y==210)
									if(num%2==1) z74=1;else v74=1;
								if(y==240)
									if(num%2==1) z75=1;else v75=1;
								if(y==270)
									if(num%2==1) z76=1;else v76=1;
								if(y==300)
									if(num%2==1) z77=1;else v77=1;;
								if(y==330)
									if(num%2==1) z78=1;else v78=1;
								if(y==360)
									if(num%2==1) z79=1;else v79=1;
								if(y==390)
									if(num%2==1) z710=1;else v710=1;//888888888888888888888888888888888888888
							end								
						if(x==250)  
							begin
								if(y==90)
									if(num%2==1) z80=1;else v80=1;	
								if(y==120)
									if(num%2==1) z81=1;else v81=1;
								if(y==150)
									if(num%2==1) z82=1;else v82=1;
								if(y==180)
									if(num%2==1) z83=1;else v83=1;
								if(y==210)
									if(num%2==1) z84=1;else v84=1;
								if(y==240)
									if(num%2==1) z85=1;else v85=1;
								if(y==270)
									if(num%2==1) z86=1;else v86=1;
								if(y==300)
									if(num%2==1) z87=1;else v87=1;;
								if(y==330)
									if(num%2==1) z88=1;else v88=1;
								if(y==360)
									if(num%2==1) z89=1;else v89=1;
								if(y==390)
									if(num%2==1) z810=1;else v810=1;//9999999999999999999999999999999999999999
							end	
						if(x==280)  
							begin
								if(y==90)
									if(num%2==1) z90=1;else v90=1;	
								if(y==120)
									if(num%2==1) z91=1;else v91=1;
								if(y==150)
									if(num%2==1) z92=1;else v92=1;
								if(y==180)
									if(num%2==1) z93=1;else v93=1;
								if(y==210)
									if(num%2==1) z94=1;else v94=1;
								if(y==240)
									if(num%2==1) z95=1;else v95=1;
								if(y==270)
									if(num%2==1) z96=1;else v96=1;
								if(y==300)
									if(num%2==1) z97=1;else v97=1;;
								if(y==330)
									if(num%2==1) z98=1;else v98=1;
								if(y==360)
									if(num%2==1) z99=1;else v99=1;
								if(y==390)
									if(num%2==1) z910=1;else v910=1;//10101010101010101010101010101010101010
							end	
						if(x==310)  
							begin
								if(y==90)
									if(num%2==1) z100=1;else v100=1;	
								if(y==120)
									if(num%2==1) z101=1;else v101=1;
								if(y==150)
									if(num%2==1) z102=1;else v102=1;
								if(y==180)
									if(num%2==1) z103=1;else v103=1;
								if(y==210)
									if(num%2==1) z104=1;else v104=1;
								if(y==240)
									if(num%2==1) z105=1;else v105=1;
								if(y==270)
									if(num%2==1) z106=1;else v106=1;
								if(y==300)
									if(num%2==1) z107=1;else v107=1;;
								if(y==330)
									if(num%2==1) z108=1;else v108=1;
								if(y==360)
									if(num%2==1) z109=1;else v109=1;
								if(y==390)
									if(num%2==1) z1010=1;else v1010=1;//11 11 11 11 11  11  11  11  11
							end														
																				
					end
            default :begin if(key_flag==1) key_flag<=1;else key_flag<=0;end
            endcase 
    end 
      assign R=rgb[0];
      assign G=rgb[1];
      assign B=rgb[2];
endmodule 
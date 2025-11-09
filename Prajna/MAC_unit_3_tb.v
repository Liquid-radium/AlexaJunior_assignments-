module MAC_unit_3_tb ;
reg [7:0] A , B ;
reg clock , reset ;

wire [15:0] S  , P;


MAC_unit_3 uut( .A(A) , .B(B) , .clock(clock) , .reset_p(reset) ,  .S(S) , .P(P)  ) ;
always #5 clock = ~clock ;
initial begin

 
$monitor("A = %d , B = %d,S= %d",A,B,S) ;

clock = 1 ;
reset = 1 ;
 
#10 ;
reset = 0;
     A = 8'd15 ;
	  B = 8'd17 ;
#10 ;
A = 8'd40 ; 
B = 8'd45 ;

#10 ;
 
A = 8'd47 ;
B = 8'd145 ;

#10;


A= 255;
B=255;
     
#10 ;
reset = 0 ;
A= 255;
B=255;
#10 ;
  

    
$finish	 ;
end

endmodule
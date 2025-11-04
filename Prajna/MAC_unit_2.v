// pipelined MAC unit

module MAC_unit_2 (input [7:0]A ,
					    input [7:0]B ,
						 input clock ,
						 input reset_p ,
						 output reg [15:0]S,
						output reg [15:0] P  ) ;

reg [17:0] sum ;



						 
always @( posedge clock , posedge reset_p ) begin
if(reset_p ==1'b1) begin 

S <= 16'd0 ;
P <= 16'd0 ;
sum<= 17'b0 ;

end
else begin 
P<= A* B ;
sum  <=  S + P ;
if ( sum >16'hffff ) S <= 16'hffff ;
else if (sum <= 16'hffff) S <= sum[15:0] ;
end
end

endmodule
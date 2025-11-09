// pipelined MAC unit

module MAC_unit_3 (input [7:0]A ,
					    input [7:0]B ,
						 input clock ,
						 input reset_p ,
						 output reg [15:0]S,
						output reg [15:0] P  ) ;


reg [7:0] reg_A , reg_B ;
always @(posedge clock , posedge reset_p) begin
if(reset_p)  begin reg_A<=8'd0 ; reg_B<=8'd0 ; end
else begin  reg_A<= A ; reg_B<= B ; end 
end
always @(posedge clock , posedge reset_p) begin
if(reset_p) P <= 16'd0 ;
else P<= (reg_A * reg_B) ;
end
always @(posedge clock , posedge reset_p) begin
if(reset_p) S <= 16'd0 ;
else S <= S + P ;
end

						 

endmodule
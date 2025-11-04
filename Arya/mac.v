module mac(input clk, input r, input [7:0] a, input [7:0] b, output reg [15:0] acc);
  	always @(posedge clk or posedge r) begin
      	if(r) acc<=0;
		else acc<=acc+a*b;
	end
endmodule

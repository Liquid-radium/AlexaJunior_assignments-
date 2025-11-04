module mac(input clk, input r, input [7:0] a, input [7:0] b, output reg [15:0] acc, output reg of);
  	wire [16:0] c=acc+a*b;
  	always @(posedge clk or posedge r) begin
      	if(r) begin
        	acc<=0;
          	of<=0;
        end
      	else if(c[16]) begin
        	acc<=16'hFFFF;
          	of<=1;
        end
        else begin
          	acc<=c[15:0];
          	of<=0;
        end
	end
endmodule

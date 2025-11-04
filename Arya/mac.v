module mac(input clk, input r, input [7:0] a, input [7:0] b, output reg [15:0] acc, output reg of);
	wire [16:0] c=acc+a*b; // this is to check for overflow
  	always @(posedge clk or posedge r) begin
		if(r) begin // rest operation
        	acc<=0;
          	of<=0;
        end
		else if(c[16]) begin // saturate acc if overflow is detected, and flag it
        	acc<=16'hFFFF;
          	of<=1;
        end
        else begin // normal mac operation
          	acc<=c[15:0];
          	of<=0;
        end
	end
endmodule

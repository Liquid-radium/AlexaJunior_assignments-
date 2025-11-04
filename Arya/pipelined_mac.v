module pipelined_mac(input clk, input r, input [7:0] a, input [7:0] b, output reg [15:0] acc, output reg of);

	// Stage 1 - inputs
  	reg [7:0] A;
  	reg [7:0] B;
  	always@(posedge clk or posedge r) begin
      	if(r) begin
          	A<=0;
          	B<=0;
        end
      	else begin
          	A<=a;
            B<=b;
        end
  	end

	// Stage 2 - product
  	reg [15:0] P;
  	always@(posedge clk or posedge r) begin
    	if(r) P<=0;
    	else P<=A*B;
  	end

	// Stage 3 - accumulator
  	wire [16:0] c=acc+P;
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

`timescale 1ns/1ps
module mac_tb;
    reg clk;
    reg r;
    reg [7:0] a;
    reg [7:0] b;
    wire [15:0] acc;
	  mac uut(clk, r, a, b, acc);
    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end
  	initial begin
      	$monitor("Time=%0t | r=%b | a=%d | b=%d | acc=%d", $time, r, a, b, acc);
      	r=1; a=0; b=0;
        #10; r=0;
      
      	a=6; b=7; #10;
      	a=5; b=4; #10;
      	a=9; b=2; #10;
      	a=3; b=8; #10;
      	r=1; #10 r=0; 
      	a=2; b=7; #10;
      	
      	$finish;
    end
endmodule

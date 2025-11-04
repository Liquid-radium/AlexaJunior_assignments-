`timescale 1ns/1ps
module pipelined_mac_tb;
    reg clk;
    reg r;
    reg [7:0] a;
    reg [7:0] b;
    wire [15:0] acc;
  	wire of;
  	pipelined_mac uut(clk, r, a, b, acc, of);
    initial begin
        clk = 1;
        forever #5 clk = ~clk; 
    end
  	initial begin
    $monitor("Time=%0t | r=%b | a=%d | b=%d | acc=%d | of=%b", $time, r, a, b, acc, of);
      	
      	r=1; a=0; b=0; #10; r=0;
      	a=6; b=9; #10;
      	a=5; b=4; #10;
      	a=9; b=2; #10;
      	a=3; b=8; #10;
      	a=0; b=0; #20;
      
      	r=1; #10 r=0;
      	a=255; b=255; #10;
      	a=40; b=40; #10;
      	a=0; b=0; #20;
      
      	r=1; #10 r=0; 
      	a=6; b=7; #10;
      	a=5; b=5; #10;
      	a=3; b=11;#10;
      	a=0; b=0; #20;
      	
      	$finish;
    end
endmodule

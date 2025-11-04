`timescale 1ns/1ps
module mac_tb;
    reg clk;
    reg r;
    reg [7:0] a;
    reg [7:0] b;
    wire [15:0] acc;
  	wire of;
  	mac uut(clk, r, a, b, acc, of);
    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end
  	initial begin
    $monitor("Time=%0t | r=%b | a=%d | b=%d | acc=%d | of=%b", $time, r, a, b, acc, of);
      	r=1; a=0; b=0; #5; r=0; //0
      	a=6; b=9; #10; // 54
      	a=5; b=4; #10; // 74
      	a=9; b=2; #10; // 92
      	a=3; b=8; #10; // 116
        r=1; #10 r=0;  //0 (reset)
      	a=255; b=255; #10; //65025
        a=40; b=40; #10;   //65535 (overflow)
      	r=1; #10 r=0;  //0
      	a=6; b=7; #10; //42
      	a=5; b=5; #10; //67
      	a=3; b=11;     //100
      	
      	$finish;
    end
endmodule

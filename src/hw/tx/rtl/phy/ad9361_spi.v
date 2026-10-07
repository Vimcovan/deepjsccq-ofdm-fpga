// ***************************************************************************
// Provenance: derived from github.com/lzk2211/Zedboard_AD9361_radar
//   (AD9361-PL-PS12demoshow/AD9361-PL-PS12demoshow.srcs/sources_1/new/ad9361_spi.v), via the MiLianKe AD9361
//   example, modified in this project. Redistributed under the MIT license with the permission of the
//   original author lzk2211: https://github.com/lzk2211/Zedboard_AD9361_radar/issues/1 (2026-10-07).
// ***************************************************************************

module ad9361_spi(
    input                               I_clk                      ,                 //20mhz
    input                               I_rst_n                    ,

    input                               I_start                    ,        //1-cycle request strobe: latch address/data and run one 24-bit transfer
    input                               I_read                     ,
    input                               I_write                    ,
    input              [   9: 0]        I_address                  ,
    input              [   7: 0]        I_writedata                ,
    output reg         [   7: 0]        O_readdata                 ,
    output reg                          O_waitrequest              ,

    output                              O_spi_clk                  ,
    output reg                          O_spi_csn                  ,
    output reg                          O_spi_mosi                 ,
    input                               I_spi_miso                  
  );

    reg                [   4: 0]        bit_cnt                     ;
    reg                [  23: 0]        command                     ;
    reg                [   1: 0]        state                       ;
    reg                [   7: 0]        readdata_reg	            ;
    wire                                wr_ctrl                     ;

    // spi_clk 20mhz
	assign O_spi_clk = I_clk;
   
    // spi_mosi
	//д write=1��read=0;  wr_ctrl=1
	//�� write=0, read=1;  wr_ctrl=0
    assign wr_ctrl = I_write & !I_read;
    always @ (posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            state			<= 'd0;
            O_spi_csn		<= 'b1;
            O_spi_mosi		<= 'b0;
            bit_cnt			<= 'b0;
            O_waitrequest	<= 'b1;					//�ȴ�״̬�ź�
		end 
		else begin
            case(state)
            	2'd0: begin
                	bit_cnt				<= 'b0;
					// idle until requested: the old code restarted a transfer here unconditionally,
					// which re-sent the previous command and shifted every ack/readdata by one transfer
					if (I_start) begin
						command			<= {wr_ctrl,3'b000,2'b00,I_address,I_writedata};
						state			<= 'd1;
					end
            	end
            	2'd1: begin
                	if(bit_cnt<=23) begin
                		O_spi_csn		<= 'b0;
                    	O_spi_mosi		<= command[23];
                    	command			<= command << 1;
                    	bit_cnt			<= bit_cnt + 'b1;
                	end
					else begin
                    	O_spi_csn		<= 'b1;
                    	O_spi_mosi		<= 'b0;
                    	bit_cnt			<= 'b0;
                    	O_waitrequest 	<= 'b0;            //24λ����д����ϣ��ȴ�״̬���ͣ���ȡ��һ��Ҫд���ֵ
						state			<= 'd2;
                	end
            	end
            	2'd2: begin
                	O_waitrequest		<= 'b1;			  
                	state				<= 'd0;
            	end
            	default: state			<= 'd0;
            endcase
        end
    end

    //spi_miso     ��ȡ����8λ����
	always @ (posedge I_clk or negedge I_rst_n) begin
		if(!I_rst_n)
			readdata_reg 	<= 'b0;
		else begin
			readdata_reg	<= {readdata_reg[6:0],I_spi_miso};
         	if(bit_cnt==24 && I_read)
				O_readdata	<= {readdata_reg[6:0],I_spi_miso};
		end
	end

endmodule


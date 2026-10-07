// ***************************************************************************
// Provenance: derived from github.com/lzk2211/Zedboard_AD9361_radar
//   (AD9361-PL-PS12demoshow/AD9361-PL-PS12demoshow.srcs/sources_1/new/ad9361_init.v), via the MiLianKe AD9361
//   example, modified in this project. Redistributed under the MIT license with the permission of the
//   original author lzk2211: https://github.com/lzk2211/Zedboard_AD9361_radar/issues/1 (2026-10-07).
// ***************************************************************************

module ad9361_config(
    input                               I_clk                      ,        //20mhz
    input                               I_rst_n                    ,

    output reg                          O_start                    ,        //1-cycle SPI request strobe
    output reg                          O_read                     ,
    output reg                          O_write                    ,
    output reg         [   9: 0]        O_address                  ,
    output reg         [   7: 0]        O_writedata                ,
    input              [   7: 0]        I_readdata                 ,
    input                               I_waitrequest              ,

    output reg                          O_resetb                   ,		//ad9361 Ӳ����λ���ţ��͵�ƽ��Ч
    output reg         [   3: 0]        O_ENSM_state               ,
    output reg                          O_ad9361_congfig_done       
);
    `include "ad9361_config_lut.v"
    reg                [  12: 0]        index                       ;       //lut����
    reg                [   2: 0]        state                       ;		
    reg                [  31: 0]        delay_cnt                   ;		
    reg                [  18: 0]        ad9361_config_lut_reg       ;

	//����ad9361�Ĵ������ұ�
    always @ (posedge I_clk) begin
        ad9361_config_lut_reg <= ad9361_config_lut(index[10:0]);   // LUT < 2048 entries: 11-bit ROM (see ad9361_config_lut.v)
    end
	
	//״̬����ȷ���Ĵ�����д��ȷ���Ĵ���������ɺ�O_ad9361_congfig_done����
	always @ (posedge I_clk or negedge I_rst_n) begin
		if(!I_rst_n) begin 
            index				  	<= 'b0;
            O_start				  	<= 'b0;
            O_write				  	<= 'b0;
            O_read					<= 'b0;
            O_address				<= 'b0;
            O_writedata				<= 'b0;
            O_ad9361_congfig_done 	<= 'b0;
            state					<= 'b0;
            delay_cnt   			<= 'b0;
            O_resetb				<= 'b0;						//ad9361 Ӳ����λ
		end
		else begin
			O_start <= 1'b0;
			case(state)
				3'd0: begin                                     //wait 1ms��O_resetb���ߣ���λ����
					if(delay_cnt != 'd20000)
						delay_cnt	<= delay_cnt + 'b1;
					else begin
						O_resetb	<= 'b1;
						delay_cnt	<= 'b0;
						state		<= 'd1;
					end
				end
				3'd1: begin 
				    {O_write,O_address,O_writedata} <= ad9361_config_lut_reg;
				    O_read						    <= ~ad9361_config_lut_reg[18];
				    O_start                         <= 1'b1;
				    state                           <= 'd2;
				end
				3'd2:begin
				    if( ~I_waitrequest ) begin             //�ȴ�״̬�źŵ͵�ƽ��Ч
				        state <= O_read ? 'd3 : 'd4;
				    end
				end
				3'd3:begin
					//�鿴�Ĵ����б���������Ҫ���Ĳ������ж϶����������Ƿ���ȷ
				    case(ad9361_config_lut_reg)
					    {1'b0,10'h037,8'h08}:begin if( I_readdata[3]) state<=state+'d1;else state<='d1;end   		
				        {1'b0,10'h05E,8'h80}:begin if( I_readdata[7]) state<=state+'d1;else state<='d1;end			
					    {1'b0,10'h244,8'h80}:begin if( I_readdata[7]) state<=state+'d1;else state<='d1;end		
					    {1'b0,10'h284,8'h80}:begin if( I_readdata[7]) state<=state+'d1;else state<='d1;end		
					    {1'b0,10'h247,8'h02}:begin if( I_readdata[1]) state<=state+'d1;else state<='d1;end		
					    {1'b0,10'h287,8'h02}:begin if( I_readdata[1]) state<=state+'d1;else state<='d1;end		
					    {1'b0,10'h016,8'h80}:begin if(!I_readdata[7]) state<=state+'d1;else state<='d1;end		
					    {1'b0,10'h016,8'h40}:begin if(!I_readdata[6]) state<=state+'d1;else state<='d1;end		
					    {1'b0,10'h016,8'h01}:begin if(!I_readdata[0]) state<=state+'d1;else state<='d1;end	
					    {1'b0,10'h016,8'h02}:begin if(!I_readdata[1]) state<=state+'d1;else state<='d1;end
					    {1'b0,10'h016,8'h10}:begin if(!I_readdata[4]) state<=state+'d1;else state<='d1;end		
					    {1'b0,10'h016,8'h20}:begin if(!I_readdata[5]) state<=state+'d1;else state<='d1;end	
					    {1'b0,10'h017,8'h0F}:
							begin 
								//��Ϊ�Ĵ����б�������FDDģʽ�����ã�����������������ȷӦ��Ϊ 'd10
								O_ENSM_state <= I_readdata[3:0]; 
								if( I_readdata[3:0] == 4'd10)                                         
									state	 <=	state + 'd1; 
								else 
									state	 <=	'd1;
							end	
					    {1'b0,10'h3FF,8'h01}:	
							begin											
							    if (delay_cnt != 'd20000)                 //wait 1ms
									delay_cnt <= delay_cnt + 'b1;								
							    else begin 
									delay_cnt <= 'b0;
									state     <= state + 'd1;
								end 
							end
					    {1'b0,10'h3FF,8'h14}:	
							begin										
							    if(delay_cnt  != 'd400000) 				  //wait 20ms
									delay_cnt <= delay_cnt + 'b1;							
							    else begin 
									delay_cnt <= 'b0;
									state     <= state+'d1;
								end	
							end		  	  														
				        {1'b0,10'h3FF,8'hFF}:begin state<='d6;      end	  //��ȡ���Ĵ����б����õĽ�����־����ת״̬6
					    default:			 begin state<=state+'d1;end
				    endcase
				end
				3'd4:   begin index<=index+'b1;state<=state+'d1;end
				3'd5:	begin state<='d1;						end	
				3'd6:   begin O_ad9361_congfig_done<='b1;       end
				default:begin state<='d0;						end
			endcase
		end
	end
endmodule
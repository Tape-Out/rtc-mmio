`ifndef RTC_BCD_MMIO_V
`define RTC_BCD_MMIO_V

`timescale 1ns/1ps

`ifndef RTC_DEFAULT_YEAR
`define RTC_DEFAULT_YEAR 32'h2026_01_01     // default date: 26-01-01
`endif

`ifndef RTC_DEFAULT_TIME
`define RTC_DEFAULT_TIME 32'h00__00__00     // default time: 00:00:00
`endif

module rtc_mmio #(
    parameter [31:0] BASE_ADDR      = 32'h8100_9000,
    parameter [31:0] CLK_FREQ       = 32'd100_000_000,      // 100MHz
    parameter [31:0] DEFAULT_YEAR   = `RTC_DEFAULT_YEAR,
    parameter [31:0] DEFAULT_TIME   = `RTC_DEFAULT_TIME,
    parameter [31:0] EXT_CLK_FREQ   = 32'd32768             // default ext_clk freq
)(
    input  wire        clk,
    input  wire        ext_clk,
    input  wire        use_ext_clk,                         // 1:use ext clk, 0:use sys clk
    input  wire        resetn,

    input  wire        mem_valid,
    input  wire        mem_instr,
    output reg         mem_ready,
    input  wire [31:0] mem_addr,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [31:0] mem_wdata,
    /* verilator lint_on  UNUSEDSIGNAL */
    input  wire [3:0]  mem_wstrb,
    output reg  [31:0] mem_rdata,

    output reg         irq,
    input  wire        eoi
);

    localparam [31:0] RW_REG_CTRL       = BASE_ADDR + 32'h00;
    localparam [31:0] RW_REG_DATE       = BASE_ADDR + 32'h04;  // YYYYMMDD
    localparam [31:0] RW_REG_TIME       = BASE_ADDR + 32'h08;  // HHMMSS
    localparam [31:0] RW_REG_ALARM_DATE = BASE_ADDR + 32'h0C;  // alarm date
    localparam [31:0] RW_REG_ALARM_TIME = BASE_ADDR + 32'h10;  // alarm time
    localparam [31:0] RO_REG_CUR_DATE   = BASE_ADDR + 32'h14;  // current date
    localparam [31:0] RO_REG_CUR_TIME   = BASE_ADDR + 32'h18;  // current time
    localparam [31:0] RW_REG_INT_MASK   = BASE_ADDR + 32'h1C;  // 1=disable curr idx irq
    localparam [31:0] RW_REG_EXT_FREQ   = BASE_ADDR + 32'h20;  // EXT_CLK_FREQ
    localparam [31:0] RO_REG_IS_LEAPY   = BASE_ADDR + 32'h24;  // is leap year
    localparam [31:0] RO_REG_MONTH_DAYS = BASE_ADDR + 32'h28;  // current month days

    reg [31:0] ctrl_reg;
    reg [31:0] date_reg;
    reg [31:0] time_reg;
    reg [31:0] alarm_date_reg;
    reg [31:0] alarm_time_reg;
    reg [31:0] int_mask_reg;
    reg [31:0] ext_freq_reg;
    reg [31:0] cur_date;
    reg [31:0] cur_time;
    reg [31:0] clk_divider;
    reg        tick_1hz;

    wire ctrl_enable     = ctrl_reg[0];
    wire ctrl_alarm_en   = ctrl_reg[1];
    wire ctrl_date_valid = ctrl_reg[3];

    wire int_mask_second = int_mask_reg[0]; // 1=disable second irq
    wire int_mask_minute = int_mask_reg[1]; // ...
    wire int_mask_hour   = int_mask_reg[2]; // ...
    wire int_mask_alarm  = int_mask_reg[3]; // ...

    reg second_irq, minute_irq, hour_irq, alarm_irq;
    reg second_tick, minute_tick, hour_tick, alarm_match;

    wire [31:0] wmask = { {8{mem_wstrb[3]}}, {8{mem_wstrb[2]}}, {8{mem_wstrb[1]}}, {8{mem_wstrb[0]}} };
    wire [31:0] wdata = mem_wdata & wmask;

    wire rtc_clk = use_ext_clk ? ext_clk : clk;
    wire [31:0] actual_ext_freq = (ext_freq_reg > 0) ? ext_freq_reg : EXT_CLK_FREQ;
    wire [31:0] target_freq = use_ext_clk ? actual_ext_freq : CLK_FREQ;
    wire [31:0] divider_value = (target_freq > 0) ? target_freq - 1 : 0;

    wire is_leap_year = ((cur_date[31:16] % 4 == 0) && (cur_date[31:16] % 100 != 0)) || (cur_date[31:16] % 400 == 0);
    wire [7:0] current_month_days;               // how much days of the curr month

    function [7:0] get_month_days;
        input [7:0] bcd_month;
        input is_leap;
        reg [7:0] decimal_month;
        reg [7:0] result;
        begin
            decimal_month = (bcd_month[7:4] * 8'd10) + {4'b0, bcd_month[3:0]};
            case (decimal_month)
                8'd1, 8'd3, 8'd5, 8'd7, 8'd8, 8'd10, 8'd12:
                    result = 8'h31;
                8'd4, 8'd6, 8'd9, 8'd11:
                    result = 8'h30;
                8'd2: begin
                    if (is_leap)
                        result = 8'h29;
                    else
                        result = 8'h28;
                end
                default: result = 8'h31;
            endcase
            get_month_days = result;
        end
    endfunction

    assign current_month_days = get_month_days(cur_date[15:8], is_leap_year);

    always @(posedge rtc_clk) begin: GEN_1Hz_TICK
        if (!resetn) begin
            clk_divider <= 0;
            tick_1hz <= 0;
        end else begin
            if (ctrl_enable && target_freq > 0) begin
                if (clk_divider >= divider_value) begin
                    clk_divider <= 0;
                    tick_1hz <= 1;
                end else begin
                    clk_divider <= clk_divider + 1;
                    tick_1hz <= 0;
                end
            end else begin
                clk_divider <= 0;
                tick_1hz <= 0;
            end
        end
    end

    always @(posedge rtc_clk) begin: RTC_TIMER
        reg [7:0] day_temp, month_temp;
        reg [15:0] year_temp;
        reg [7:0] month_days_temp;
        reg second_tick, minute_tick, hour_tick, alarm_match;

        if (!resetn) begin
            cur_date <= DEFAULT_YEAR;
            cur_time <= DEFAULT_TIME;
        end else begin
            second_tick = 0;
            minute_tick = 0;
            hour_tick = 0;
            alarm_match = 0;

            if (ctrl_enable && tick_1hz) begin
                if (cur_time[7:0] < 8'h59) begin: SECOND
                    if (cur_time[3:0] < 4'h9) begin
                        cur_time[3:0] <= cur_time[3:0] + 1;
                    end else begin
                        cur_time[3:0] <= 0;
                        cur_time[7:4] <= cur_time[7:4] + 1;
                    end
                end else begin
                    cur_time[7:0] <= 0;
                    second_tick = 1;

                    if (cur_time[15:8] < 8'h59) begin: MINUTE
                        if (cur_time[11:8] < 4'h9) begin
                            cur_time[11:8] <= cur_time[11:8] + 1;
                        end else begin
                            cur_time[11:8] <= 0;
                            cur_time[15:12] <= cur_time[15:12] + 1;
                        end
                    end else begin
                        cur_time[15:8] <= 0;
                        minute_tick = 1;

                        if (cur_time[23:16] < 8'h23) begin: HOUR
                            if (cur_time[19:16] < 4'h9) begin
                                cur_time[19:16] <= cur_time[19:16] + 1;
                            end else begin
                                cur_time[19:16] <= 0;
                                cur_time[23:20] <= cur_time[23:20] + 1;
                            end
                        end else begin: YYYYMMDD
                            cur_time[23:16] <= 0;
                            hour_tick = 1;

                            day_temp = cur_date[7:0];
                            month_temp = cur_date[15:8];
                            year_temp = cur_date[31:16];
                            month_days_temp = get_month_days(month_temp, is_leap_year);

                            if (day_temp < month_days_temp) begin: DD
                                if (day_temp[3:0] < 4'h9) begin
                                    day_temp[3:0] = day_temp[3:0] + 1;
                                end else begin
                                    day_temp[3:0] = 0;
                                    day_temp[7:4] = day_temp[7:4] + 1;
                                end
                            end else begin: MM
                                day_temp = 8'h01;

                                if (month_temp < 8'h12) begin
                                    if (month_temp[3:0] < 4'h9) begin
                                        month_temp[3:0] = month_temp[3:0] + 1;
                                    end else begin
                                        month_temp[3:0] = 0;
                                        month_temp[7:4] = month_temp[7:4] + 1;
                                    end
                                end else begin: YYYY
                                    month_temp = 8'h01;

                                    if (year_temp[3:0] < 4'h9) begin
                                        year_temp[3:0] = year_temp[3:0] + 1;
                                    end else begin
                                        year_temp[3:0] = 0;
                                        if (year_temp[7:4] < 4'h9) begin
                                            year_temp[7:4] = year_temp[7:4] + 1;
                                        end else begin
                                            year_temp[7:4] = 0;
                                            if (year_temp[11:8] < 4'h9) begin
                                                year_temp[11:8] = year_temp[11:8] + 1;
                                            end else begin
                                                year_temp[11:8] = 0;
                                                if (year_temp[15:12] < 4'h9) begin
                                                    year_temp[15:12] = year_temp[15:12] + 1;
                                                end else begin
                                                    year_temp[15:12] = 0;
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                            cur_date <= {year_temp, month_temp, day_temp};
                        end
                    end
                end
                if (ctrl_alarm_en && (cur_date == alarm_date_reg) && (cur_time == alarm_time_reg)) begin
                    alarm_match = 1;
                end
            end
        end
    end

    always @(posedge rtc_clk) begin
        if (!resetn || eoi) begin
            irq <= 0;
            second_irq <= 0;
            minute_irq <= 0;
            hour_irq <= 0;
            alarm_irq <= 0;
        end else begin
            if (second_tick && !int_mask_second) second_irq <= 1;
            if (minute_tick && !int_mask_minute) minute_irq <= 1;
            if (hour_tick && !int_mask_hour) hour_irq <= 1;
            if (alarm_match && !int_mask_alarm) alarm_irq <= 1;
            irq <= second_irq || minute_irq || hour_irq || alarm_irq;
        end
    end

    always @(posedge clk) begin
        if (!resetn) begin
            mem_ready <= 0;
        end
        mem_ready <= mem_valid && !mem_instr;
    end

    always @(posedge clk) begin: MMIO_READ
        if (!resetn) begin
            mem_rdata <= 0;
        end else begin
            if (mem_valid && (!mem_instr) && mem_wstrb == 0) begin
                case (mem_addr)
                    RW_REG_CTRL:        mem_rdata <= ctrl_reg;
                    RW_REG_DATE:        mem_rdata <= date_reg;
                    RW_REG_TIME:        mem_rdata <= time_reg;
                    RW_REG_ALARM_DATE:  mem_rdata <= alarm_date_reg;
                    RW_REG_ALARM_TIME:  mem_rdata <= alarm_time_reg;
                    RO_REG_CUR_DATE:    mem_rdata <= cur_date;
                    RO_REG_CUR_TIME:    mem_rdata <= cur_time;
                    RW_REG_INT_MASK:    mem_rdata <= int_mask_reg;
                    RW_REG_EXT_FREQ:    mem_rdata <= ext_freq_reg;
                    RO_REG_IS_LEAPY:    mem_rdata <= {31'b0, is_leap_year};
                    RO_REG_MONTH_DAYS:  mem_rdata <= {24'b0, current_month_days};
                    default:            mem_rdata <= 32'h0;
                endcase
            end else begin
                mem_rdata <= 0;
            end
        end
    end

    integer j;
    always @(posedge clk) begin: MMIO_WRITE
        if (!resetn) begin
            ctrl_reg <= 0;
            date_reg <= DEFAULT_YEAR;
            time_reg <= DEFAULT_TIME;
            alarm_date_reg <= DEFAULT_YEAR;
            alarm_time_reg <= DEFAULT_TIME;
            int_mask_reg <= 32'hF;
            ext_freq_reg <= EXT_CLK_FREQ;
        end else begin
            if (mem_valid && (!mem_instr) && mem_wstrb != 0) begin
                case(mem_addr)
                    RW_REG_CTRL:        ctrl_reg <= wdata;
                    RW_REG_DATE:        date_reg <= wdata;
                    RW_REG_TIME:        time_reg <= wdata;
                    RW_REG_ALARM_DATE:  alarm_date_reg <= wdata;
                    RW_REG_ALARM_TIME:  alarm_time_reg <= wdata;
                    RW_REG_INT_MASK:    int_mask_reg <= wdata;
                    RW_REG_EXT_FREQ:    ext_freq_reg <= (wdata > 0) ? wdata : EXT_CLK_FREQ;
                endcase
            end
        end
    end

endmodule

`endif

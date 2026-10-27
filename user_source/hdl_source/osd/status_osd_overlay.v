`timescale 1ns/1ps

// ============================================================================
// OSD字幕叠加 —— 12位状态OSD渲染核心（5×7点阵字库）
//
//
//   · 模块代码 = 常规做法
//   · font_row 字库函数 = 常规做法，这里补回）
//
// 一句话作用：在屏幕左上角一块 32×8 像素的小框里，画 4 个字符：
//     第1个字 = 当前图片编号(1~4)
//     第2个字 = A(自动轮播中) / E(手动模式)
//     第3个字 = 错误码高4位
//     第4个字 = 错误码低4位
// 正常(错误码=0)时字是黄色的，出错时字是红色的。
// ============================================================================
module status_osd_overlay #(
    parameter integer OSD_X = 8,
    parameter integer OSD_Y = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,   // 帧开始（锁存状态）
    input  wire [1:0]  active_index,  // 当前图片编号
    input  wire        auto_enabled,  // 自动/手动
    input  wire [7:0]  error_code,    // 错误码
    input  wire        in_de,
    input  wire [11:0] in_rgb,        // 输入12位RGB
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    output reg  [11:0] out_rgb,       // 输出12位RGB
    output reg         out_de,
    output wire        osd_pixel      // OSD像素标志
);
    // ---- 帧边界锁存寄存器 ----
    reg [1:0] index_q;    // 锁存的图片编号
    reg auto_q;           // 锁存的自动/手动
    reg [7:0] error_q;    // 锁存的错误码

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            index_q <= 2'd0;
            auto_q <= 1'b0;
            error_q <= 8'd0;
        end else if (frame_start) begin
            // 只在帧开始时更新，一帧内保持不变（防止一帧里上半截旧字、下半截新字＝撕裂）
            index_q <= active_index;
            auto_q <= auto_enabled;
            error_q <= error_code;
        end
    end

    // ---- 字体ROM函数（常规做法，支持 0-9 A E F）----
    function [4:0] font_row;
        input [3:0] value;   // 字符值（0-F）
        input [2:0] row;     // 行号（0-6）
        begin
            case (value)
                // 字符"0"：外框，内部空
                4'h0: case(row)
                    0:font_row=5'b11111; 1:font_row=5'b10001;
                    2:font_row=5'b10001; 3:font_row=5'b10001;
                    4:font_row=5'b10001; 5:font_row=5'b10001;
                    default:font_row=5'b11111;
                endcase
                // 字符"1"：右侧竖线+顶部斜
                4'h1: case(row)
                    0:font_row=5'b00100; 1:font_row=5'b01100;
                    2:font_row=5'b00100; 3:font_row=5'b00100;
                    4:font_row=5'b00100; 5:font_row=5'b00100;
                    default:font_row=5'b11111;
                endcase
                // 字符"2"
                4'h2: case(row)
                    0:font_row=5'b11111; 1:font_row=5'b00001;
                    2:font_row=5'b00001; 3:font_row=5'b11111;
                    4:font_row=5'b10000; 5:font_row=5'b10000;
                    default:font_row=5'b11111;
                endcase
                // 字符"3"
                4'h3: case(row)
                    0:font_row=5'b11111; 1:font_row=5'b00001;
                    2:font_row=5'b00001; 3:font_row=5'b11111;
                    4:font_row=5'b00001; 5:font_row=5'b00001;
                    default:font_row=5'b11111;
                endcase
                // 字符"4"
                4'h4: case(row)
                    0:font_row=5'b10001; 1:font_row=5'b10001;
                    2:font_row=5'b10001; 3:font_row=5'b11111;
                    4:font_row=5'b00001; 5:font_row=5'b00001;
                    default:font_row=5'b00001;
                endcase
                // 字符"5"
                4'h5: case(row)
                    0:font_row=5'b11111; 1:font_row=5'b10000;
                    2:font_row=5'b10000; 3:font_row=5'b11111;
                    4:font_row=5'b00001; 5:font_row=5'b00001;
                    default:font_row=5'b11111;
                endcase
                // 字符"6"
                4'h6: case(row)
                    0:font_row=5'b11111; 1:font_row=5'b10000;
                    2:font_row=5'b10000; 3:font_row=5'b11111;
                    4:font_row=5'b10001; 5:font_row=5'b10001;
                    default:font_row=5'b11111;
                endcase
                // 字符"7"
                4'h7: case(row)
                    0:font_row=5'b11111; 1:font_row=5'b00001;
                    2:font_row=5'b00010; 3:font_row=5'b00100;
                    4:font_row=5'b01000; 5:font_row=5'b01000;
                    default:font_row=5'b01000;
                endcase
                // 字符"8"
                4'h8: case(row)
                    0:font_row=5'b11111; 1:font_row=5'b10001;
                    2:font_row=5'b10001; 3:font_row=5'b11111;
                    4:font_row=5'b10001; 5:font_row=5'b10001;
                    default:font_row=5'b11111;
                endcase
                // 字符"9"
                4'h9: case(row)
                    0:font_row=5'b11111; 1:font_row=5'b10001;
                    2:font_row=5'b10001; 3:font_row=5'b11111;
                    4:font_row=5'b00001; 5:font_row=5'b00001;
                    default:font_row=5'b11111;
                endcase
                // 字符"A"（Auto自动模式）
                4'ha: case(row)
                    0:font_row=5'b01110; 1:font_row=5'b10001;
                    2:font_row=5'b10001; 3:font_row=5'b11111;
                    4:font_row=5'b10001; 5:font_row=5'b10001;
                    default:font_row=5'b10001;
                endcase
                // 字符"E"（手动模式）
                4'he: case(row)
                    0:font_row=5'b11111; 1:font_row=5'b10000;
                    2:font_row=5'b10000; 3:font_row=5'b11110;
                    4:font_row=5'b10000; 5:font_row=5'b10000;
                    default:font_row=5'b11111;
                endcase
                // 字符"F"（错误码十六进制用）
                4'hf: case(row)
                    0:font_row=5'b11111; 1:font_row=5'b10000;
                    2:font_row=5'b10000; 3:font_row=5'b11110;
                    4:font_row=5'b10000; 5:font_row=5'b10000;
                    default:font_row=5'b10000;
                endcase
                default: font_row = 5'b00000;  // 不支持的字符不显示
            endcase
        end
    endfunction

    // ---- 像素渲染组合逻辑（每个像素时钟都在算：这个点要不要盖章）----
    reg osd_hit;
    reg [3:0] char_value;
    reg [2:0] char_row;
    reg [2:0] char_col;
    reg [4:0] glyph_row;

    always @* begin
        osd_hit = 1'b0;
        char_value = 4'h0;
        char_row = pixel_y - OSD_Y;       // 当前像素在字符内的行号（0-7）
        char_col = pixel_x - OSD_X;       // 当前像素在OSD区域内的列号（0-31）
        glyph_row = 5'b00000;

        // OSD区域：32像素宽×8像素高
        if (pixel_x >= OSD_X && pixel_x < OSD_X + 32 &&
            pixel_y >= OSD_Y && pixel_y < OSD_Y + 8) begin

            // 4个字符，每个8像素宽
            case ((pixel_x - OSD_X) / 8)
                0: char_value = {2'b00, index_q} + 1'b1; // 图片编号1-4
                1: char_value = auto_q ? 4'ha : 4'he;     // A自动/E手动
                2: char_value = error_q[7:4];             // 错误码高半字节
                3: char_value = error_q[3:0];             // 错误码低半字节
                default: char_value = 4'h0;
            endcase

            glyph_row = font_row(char_value, char_row);

            // 前5列是字模，后3列是间距；只显示7行
            if ((pixel_x - OSD_X) % 8 < 5 && char_row < 7)
                osd_hit = glyph_row[4 - ((pixel_x - OSD_X) % 8)];
        end

        out_de = in_de;
        out_rgb = in_rgb;
        // 正常状态黄色(12'hff0)，错误状态红色(12'hf44)
        if (in_de && osd_hit)
            out_rgb = error_q == 0 ? 12'hff0 : 12'hf44;
    end

    assign osd_pixel = osd_hit && in_de;
endmodule

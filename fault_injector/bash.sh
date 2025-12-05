#!/bin/bash

# --- 配置参数 ---
TOTAL_RUNS=100000
PIN_TOOL_PATH="obj-intel64/bit_flippers.so"
TARGET_PROGRAM="./test/simple_test"
OUTPUT_FILE="out.txt"
BAR_WIDTH=50 # 进度条的长度

# --- 检查文件 ---
if [ ! -f $PIN_TOOL_PATH ] || [ ! -x $TARGET_PROGRAM ]; then
    echo "错误: Pin Tool ($PIN_TOOL_PATH) 或目标程序 ($TARGET_PROGRAM) 不存在或不可执行。"
    exit 1
fi

# --- 初始化 ---
# 清空之前的输出文件，并写入开始信息
echo "=== 启动 $TOTAL_RUNS 次测试 ===" > "$OUTPUT_FILE"
echo "测试结果将记录在: $OUTPUT_FILE"
START_TIME=$(date +%s)
# 禁用屏幕上的进度条，防止干扰后续的输出
trap "tput cnorm" EXIT # 确保退出时恢复光标

# --- 进度条函数 ---
# $1: 当前迭代次数, $2: 总次数
show_progress() {
    local CURRENT=$1
    local TOTAL=$2
    
    # 计算百分比
    local PERCENT=$(( (CURRENT * 100) / TOTAL ))
    
    # 计算进度条的填充长度
    local FILLED_WIDTH=$(( (PERCENT * BAR_WIDTH) / 100 ))
    local EMPTY_WIDTH=$(( BAR_WIDTH - FILLED_WIDTH ))
    
    # 构造填充部分
    local FILLED=$(printf "#%.0s" $(seq 1 $FILLED_WIDTH))
    # 构造空缺部分
    local EMPTY=$(printf -- "-%.0s" $(seq 1 $EMPTY_WIDTH))
    
    # 使用 \r (回车) 将光标移到行首，实现覆盖刷新
    printf "\r[${FILLED}${EMPTY}] %3d%% (%d/%d)" "$PERCENT" "$CURRENT" "$TOTAL"
}

# --- 主循环 ---
echo "开始执行..."
# 隐藏光标，让进度条更美观
tput civis

for ((i=1; i<=TOTAL_RUNS; i++)); do
    # 1. 执行程序，并将所有输出（stdout 和 stderr）追加到 OUTPUT_FILE
    # >/dev/null 2>&1 是为了确保 Pin 和程序本身的输出不会打印到屏幕，而是进入重定向的文件
    pin -t "$PIN_TOOL_PATH" -- "$TARGET_PROGRAM" >> "$OUTPUT_FILE" 2>&1

    # 2. 更新进度条 (在屏幕上显示，不写入文件)
    # 只有当达到特定的步进或最后一次迭代时才刷新，以减少 I/O 负担
    if (( i % 100 == 0 || i == TOTAL_RUNS )); then
        show_progress "$i" "$TOTAL_RUNS"
    fi
done

# --- 结束清理 ---
END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
tput cnorm # 恢复光标
echo "" # 确保进度条后换行
echo "=== 100000 次测试完成 ==="
echo "总耗时: ${DURATION} 秒"
echo "总耗时: ${DURATION} 秒" >> "$OUTPUT_FILE"

# 检查日志文件大小以确保成功
if [ -s "$OUTPUT_FILE" ]; then
    echo "日志文件 ($OUTPUT_FILE) 已生成，包含 $(wc -l < $OUTPUT_FILE) 行记录。"
else
    echo "警告: 日志文件 ($OUTPUT_FILE) 为空。"
fi
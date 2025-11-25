#!/bin/bash
set -e

# ============================
# 基本参数
# ============================
EXEC="./simple_test"        # 要测试的程序
EXEC_ARGS=""                # 程序参数，如需可以写这里
PIN_TOOL_PROF="pin_tool/obj-intel64/profiler.so"
PIN_TOOL_FI="fault_injector/obj-intel64/bit_flippers.so"
CSV_DIR="csv_file"
STAT_CSV="$CSV_DIR/stat.csv"
FSS_CSV="$CSV_DIR/stat_FSS_Score.csv"

SAMPLE_INTERVAL=10000
EXPECTED_OUTPUT="705082704"   # simple_test 的输出结果，请根据你的程序修改

OUTCOME_FILE="outcome.txt"
mkdir -p $CSV_DIR
echo "" > $OUTCOME_FILE    # 清空

echo "========== Fault Injection Campaign ==========" | tee -a $OUTCOME_FILE
echo "" | tee -a $OUTCOME_FILE

# ============================================================
# Step 1: 使用 profiler 收集 stat.csv
# ============================================================
echo "[Step 1] Collecting instruction statistics..." | tee -a $OUTCOME_FILE

setarch $(uname -m) -R pin -t $PIN_TOOL_PROF \
    -o $STAT_CSV \
    -sample_interval $SAMPLE_INTERVAL \
    -- $EXEC $EXEC_ARGS

echo "stat.csv generated: $STAT_CSV" | tee -a $OUTCOME_FILE
echo "" | tee -a $OUTCOME_FILE

# ============================================================
# Step 2: 运行 Python 计算 FSS Score
# ============================================================
echo "[Step 2] Calculating FSS Score..." | tee -a $OUTCOME_FILE

python3 FSS_calculation/calculate.py $STAT_CSV

if [ ! -f "$FSS_CSV" ]; then
    echo "Error: FSS output file not found: $FSS_CSV" | tee -a $OUTCOME_FILE
    exit 1
fi

echo "FSS Score file: $FSS_CSV" | tee -a $OUTCOME_FILE
echo "" | tee -a $OUTCOME_FILE

# ============================================================
# Step 3: Fault Injection
# ============================================================
echo "[Step 3] Running fault injection..." | tee -a $OUTCOME_FILE

CRASH=0
SDC=0
CORRECT=0

# 跳过 CSV 第一行标题
tail -n +2 "$FSS_CSV" | while IFS=',' read -r ID PC Opcode Bitwidth ExecCount AvgLat MemLevel BranchCount OpcodeNum OpcodeNorm BitNorm ExecNorm LatNorm FSSScore
do
    PC_ADDR="$PC"

    # 无效行跳过
    if [ -z "$PC_ADDR" ]; then
        continue
    fi

    # 注错次数 = round(FSS * 100)
    INJ=$(printf "%.0f" "$(echo "$FSSScore * 100" | bc -l)")
    TOTAL_EXEC=$(printf "%.0f" "$ExecCount")

    if [ "$INJ" -le 0 ] || [ "$TOTAL_EXEC" -le 0 ]; then
        continue
    fi

    echo "------------------------------------------" | tee -a $OUTCOME_FILE
    echo "PC = $PC_ADDR" | tee -a $OUTCOME_FILE
    echo "FSS = $FSSScore → Inject $INJ times" | tee -a $OUTCOME_FILE
    echo "Execution count = $TOTAL_EXEC" | tee -a $OUTCOME_FILE
    echo "------------------------------------------" | tee -a $OUTCOME_FILE

    for ((i=1; i<=INJ; i++)); do
        # 随机挑选一个 occ（第几次执行注错）
        OCC=$(shuf -i 1-$TOTAL_EXEC -n 1)

        echo "" | tee -a $OUTCOME_FILE
        echo "[Inject $i/$INJ] PC=$PC_ADDR OCC=$OCC" | tee -a $OUTCOME_FILE

        CMD="setarch $(uname -m) -R pin -t $PIN_TOOL_FI -addr $PC_ADDR -occ $OCC -- $EXEC $EXEC_ARGS"
        echo "CMD: $CMD" | tee -a $OUTCOME_FILE

        OUT=$($CMD 2>&1)
        RET=$?

        echo "$OUT" | tee -a $OUTCOME_FILE

        # 1) Crash
        if [ $RET -ne 0 ]; then
            echo "[RESULT = CRASH]" | tee -a $OUTCOME_FILE
            CRASH=$((CRASH+1))
            continue
        fi

        # 提取程序输出中的数字（simple_test）
        RESULT=$(echo "$OUT" | grep -o '[0-9]\+' | head -n1)

        # 2) SDC
        if [ "$RESULT" != "$EXPECTED_OUTPUT" ]; then
            echo "[RESULT = SDC] result=$RESULT expected=$EXPECTED_OUTPUT" | tee -a $OUTCOME_FILE
            SDC=$((SDC+1))
        else
            # 3) Correct
            echo "[RESULT = CORRECT]" | tee -a $OUTCOME_FILE
            CORRECT=$((CORRECT+1))
        fi

    done

done

# ============================================================
# 最终统计
# ============================================================
echo "" | tee -a $OUTCOME_FILE
echo "====================== FINAL SUMMARY ======================" | tee -a $OUTCOME_FILE
echo "Correct: $CORRECT" | tee -a $OUTCOME_FILE
echo "SDC:     $SDC" | tee -a $OUTCOME_FILE
echo "Crash:   $CRASH" | tee -a $OUTCOME_FILE
echo "===========================================================" | tee -a $OUTCOME_FILE

echo "[DONE] All results saved to outcome.txt"

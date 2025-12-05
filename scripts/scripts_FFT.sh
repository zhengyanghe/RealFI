#!/bin/bash
# ================== CONFIG (FFT version) ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/FFT -o"                                   # <-- 执行文件
PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"
CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/fft_stat.csv"                         # <-- 改名
INCREMENTAL_STAT="$CSV_DIR/fft_stat_incremental.csv"
FSS="$CSV_DIR/fft_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_fft.csv"          # <-- 改名
PLAN_RESULT="$ROOT/scripts/injection_plan_fft_result.csv"
OUTCOME="$ROOT/scripts/outcome_fft.txt"              # <-- 改名
SAMPLE_INTERVAL=1000
TOTAL_INJECTIONS=1000
TIMEOUT_LIMIT=60   # seconds

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan.py"

echo "Fault injection run for FFT started at $(date)"
echo "Config: EXEC='$EXEC' SAMPLE_INTERVAL=$SAMPLE_INTERVAL TOTAL_INJECTIONS=$TOTAL_INJECTIONS TIMEOUT=${TIMEOUT_LIMIT}s"
echo ""

mkdir -p "$CSV_DIR"
mkdir -p "$ROOT/scripts"

# =============================================
# Step 1: Run Profiler
# =============================================
echo "[Step 1] Running profiler → $STAT"
CMD="setarch $(uname -m) -R pin -t $PIN_TOOL -o $STAT -sample_interval $SAMPLE_INTERVAL -- $EXEC"
echo "Command: $CMD"
$CMD || { echo "ERROR: Profiler failed."; exit 1; }
echo "Profiler completed"
echo ""

# =============================================
# Step 2: Run FSS Calculation
# =============================================
echo "[Step 2] Running FSS calculation"
python3 "$INCREMENTAL_STAT_PY" "$STAT" "$INCREMENTAL_STAT" || { echo "ERROR: Incremental failed"; exit 1; }
python3 "$CALC_PY" "$INCREMENTAL_STAT" || { echo "ERROR: FSS calculation failed"; exit 1; }
echo "FSS file: $FSS"
echo ""

# =============================================
# Step 3: Generate injection plan
# =============================================
echo "[Step 3] Generating injection plan"
python3 "$PLAN_PY" "$FSS" "$TOTAL_INJECTIONS" "$PLAN" || { echo "ERROR: Plan generation failed"; exit 1; }
echo "Plan → $PLAN"
echo ""

# =============================================
# Step 4: Get golden output (only the 1024 complex numbers after FFT)
# =============================================
echo "[Step 4] Obtaining golden FFT result..."
BASE_OUTPUT=$($EXEC 2>/dev/null)
# 提取 "Data values after FFT:" 之后的所有浮点数（2048 个 real/imag 对）
GOLDEN_FFT=$(echo "$BASE_OUTPUT" | \
    sed -n '/Data values after FFT:/,/PROCESS STATISTICS/p' | \
    grep -E '[-0-9.]+ [ -][0-9.]+,' | \
    tr -d ',' | \
    tr '\n' ' ' | \
    sed 's/ $//')

if [ -z "$GOLDEN_FFT" ]; then
    echo "ERROR: Cannot extract golden FFT data!"
    exit 1
fi
echo "Golden FFT data extracted (2048 floats)"
echo ""

# =============================================
# Step 5: Fault Injection + correctness check
#   数值判定完全按原来的方法：
#     - 先字符串完全相等
#     - 再用 awk 做 1e-8 容差
#   只在“数值 CORRECT”时看 Successful termination: YES/NO
#     - YES → CORRECT
#     - NO  → NOINJECT
# =============================================
echo "[Step 5] Starting fault injection (timeout ${TIMEOUT_LIMIT}s)"
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo ">>> Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    # 带超时的注入运行（捕获完整输出，包括 Pintool 的 YES/NO）
    OUTP=$(timeout ${TIMEOUT_LIMIT}s \
           setarch $(uname -m) -R pin -t "$FI_TOOL" -addr "$PC" -occ "$OCC" -- $EXEC \
           2>&1)
    RET=$?

    echo "$OUTP" >> "$OUTCOME"

    # ---------- Timeout or other non-zero exit → CRASH ----------
    if [ $RET -eq 124 ]; then
        echo "[CRASH] timeout" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi
    if [ $RET -ne 0 ]; then
        echo "[CRASH] abnormal exit (code $RET)" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi

    # ---------- 提取注入后的 FFT 数据（保持原有提取方式） ----------
    INJECTED_FFT=$(echo "$OUTP" | \
        sed -n '/Data values after FFT:/,/PROCESS STATISTICS/p' | \
        grep -E '[-0-9.]+ [ -][0-9.]+,' | \
        tr -d ',' | \
        tr '\n' ' ' | \
        sed 's/ $//')

    # ---------- 数值比较逻辑：完全照你原来的方法 ----------
    IS_CORRECT_NUM=0

    if [ "$GOLDEN_FFT" = "$INJECTED_FFT" ]; then
        IS_CORRECT_NUM=1
    else
        DIFF=$(echo "$GOLDEN_FFT $INJECTED_FFT" | awk '
            {
                n = NF/2
                for(i=1; i<=n; i++) {
                    g = $(i);   f = $(i+n)
                    if (sqrt((g-f)*(g-f)) > 1e-8) { print "DIFF"; exit }
                }
                print "SAME"
            }')
        if [ "$DIFF" = "SAME" ]; then
            IS_CORRECT_NUM=1
        fi
    fi

    if [ $IS_CORRECT_NUM -eq 1 ]; then
        # 数值上和 GOLDEN 完全一致 / 在 1e-8 容差内
        # 现在再看 Pintool 的标记：YES → CORRECT, NO → NOINJECT
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] FFT result identical (or within 1e-8), FI activated." | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        elif echo "$OUTP" | grep -q "Successful termination: NO"; then
            echo "[NOINJECT] FFT result identical, but FI did not hit target." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        else
            # 理论上应该有 YES/NO，这里兜底当 NOINJECT
            echo "[NOINJECT] FFT result identical, but no YES/NO marker found." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        echo "[SDC] FFT result differs" | tee -a "$OUTCOME"
        echo "$PC,$OCC,SDC" >> "$PLAN_RESULT"
    fi
done

# =============================================
# Step 6: Summary
# =============================================
echo "" | tee -a "$OUTCOME"
echo "================== FINAL SUMMARY (FFT) ==================" | tee -a "$OUTCOME"
CRASH_COUNT=$(grep -c ",CRASH$" "$PLAN_RESULT")
SDC_COUNT=$(grep -c ",SDC$" "$PLAN_RESULT")
CORRECT_COUNT=$(grep -c ",CORRECT$" "$PLAN_RESULT")
NOINJECT_COUNT=$(grep -c ",NOINJECT$" "$PLAN_RESULT")
TOTAL=$((CRASH_COUNT + SDC_COUNT + CORRECT_COUNT + NOINJECT_COUNT))

echo "Total Injections     : $TOTAL"          | tee -a "$OUTCOME"
echo "CRASH                : $CRASH_COUNT"    | tee -a "$OUTCOME"
echo "SDC                  : $SDC_COUNT"      | tee -a "$OUTCOME"
echo "CORRECT              : $CORRECT_COUNT"  | tee -a "$OUTCOME"
echo "NOINJECT (no FI hit) : $NOINJECT_COUNT" | tee -a "$OUTCOME"

# 只在真正有注入（CORRECT+SDC）里算 SDC rate
echo "SDC rate (injected only) : $(echo "scale=4; if(($SDC_COUNT+$CORRECT_COUNT)>0) $SDC_COUNT*100/($SDC_COUNT+$CORRECT_COUNT) else 0" | bc)%" | tee -a "$OUTCOME"
echo "========================================================" | tee -a "$OUTCOME"

echo "All done! Results in:"
echo "   Plan result : $PLAN_RESULT"
echo "   Full log    : $OUTCOME"
exit 0

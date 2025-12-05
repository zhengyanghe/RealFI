#!/bin/bash

# ================== CONFIG for LULESH (deterministic) ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/lulesh2.0"

# 你验证过 100% 确定性的参数
LULESH_ARGS="-i 5 -s 10"
export OMP_NUM_THREADS=1

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/lulesh_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/lulesh_stat_incremental.csv"
FSS="$CSV_DIR/lulesh_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_lulesh.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_lulesh_result.csv"
OUTCOME="$ROOT/scripts/outcome_lulesh.txt"

SAMPLE_INTERVAL=1000
TOTAL_INJECTIONS=1000
TIMEOUT_LIMIT=300          # 单次约 0.003~0.016 秒，300 秒绰绰有余

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan.py"

echo "Fault injection run for LULESH started at $(date)"
echo "Config: TOTAL_INJECTIONS=$TOTAL_INJECTIONS  Args: $LULESH_ARGS  OMP_NUM_THREADS=1"
mkdir -p "$CSV_DIR" "$ROOT/scripts"

# =============================================
# Step 1: Run Profiler
# =============================================
echo "[Step 1] Running profiler → $STAT"
setarch $(uname -m) -R pin -t $PIN_TOOL -o $STAT -sample_interval $SAMPLE_INTERVAL -- $EXEC $LULESH_ARGS \
    >/dev/null 2>&1 || { echo "ERROR: Profiler failed"; exit 1; }
echo "Profiler done"

# =============================================
# Step 2: FSS Calculation
# =============================================
echo "[Step 2] Running FSS calculation"
python3 "$INCREMENTAL_STAT_PY" "$STAT" "$INCREMENTAL_STAT" || exit 1
python3 "$CALC_PY" "$INCREMENTAL_STAT" || exit 1
echo "FSS file: $FSS"

# =============================================
# Step 3: Generate injection plan
# =============================================
echo "[Step 3] Generating injection plan → $PLAN"
python3 "$PLAN_PY" "$FSS" "$TOTAL_INJECTIONS" "$PLAN" || exit 1
echo "Plan saved to $PLAN"

# =============================================
# Step 4: Fault Injection — 严格比对所有关键物理结果
#   只在候选 CORRECT 时检查 Pintool 注入标志
# =============================================
echo "[Step 4] Starting fault injection → $PLAN_RESULT"
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

# 预先跑一次黄金输出，只提取关键物理行作为签名（内存中保存）
echo "Generating reference golden signature (only physical results)..."
GOLDEN_SIGN=$( OMP_NUM_THREADS=1 "$EXEC" $LULESH_ARGS 2>/dev/null | \
    grep -E "Problem size|Iteration count|Final Origin Energy|MaxAbsDiff|TotalAbsDiff|MaxRelDiff" )

echo "Golden signature locked (6 critical lines):"
echo "$GOLDEN_SIGN"
echo "----------------------------------------" >> "$OUTCOME"
echo "LULESH GOLDEN PHYSICAL SIGNATURE:" >> "$OUTCOME"
echo "$GOLDEN_SIGN" >> "$OUTCOME"
echo "----------------------------------------" >> "$OUTCOME"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    # 注入命令（必须设置 OMP_NUM_THREADS=1）
    INJECT_CMD="OMP_NUM_THREADS=1 setarch $(uname -m) -R pin -t $FI_TOOL -addr $PC -occ $OCC -- $EXEC $LULESH_ARGS"

    # 带超时运行注入
    OUTP=$(timeout $TIMEOUT_LIMIT bash -c "$INJECT_CMD" 2>&1)
    RET=$?

    # 记录完整输出用于调试
    echo "$OUTP" >> "$OUTCOME"
    echo "----------------------------------------" >> "$OUTCOME"

    # ---------- CRASH 判断 ----------
    if [ $RET -eq 124 ]; then
        echo "[CRASH] timeout > ${TIMEOUT_LIMIT}s" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi
    if [ $RET -ne 0 ]; then
        echo "[CRASH] exit code $RET (segfault/hang/etc)" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi

    # 提取本次注入的 6 行关键物理结果
    INJECT_SIGN=$(echo "$OUTP" | \
        grep -E "Problem size|Iteration count|Final Origin Energy|MaxAbsDiff|TotalAbsDiff|MaxRelDiff" )

    # 严格字符串比对（6 行必须完全一致）
    echo "$INJECT_SIGN"
    echo "$GOLDEN_SIGN"
    if [ "$INJECT_SIGN" = "$GOLDEN_SIGN" ]; then
        # 候选 CORRECT：此时才检查 Pintool 是否真正注入成功
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] All 6 physical metrics identical (Final Energy = 3.268917e+05 etc.), fault injected." | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        else
            echo "[NOINJECT] Output matches GOLDEN, but Pintool reports no fault injected." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        echo "[SDC] Physical result corrupted!" | tee -a "$OUTCOME"
        echo ">>> GOLDEN:" >> "$OUTCOME"
        echo "$GOLDEN_SIGN" >> "$OUTCOME"
        echo ">>> INJECTED:" >> "$OUTCOME"
        echo "$INJECT_SIGN" >> "$OUTCOME"
        echo "$PC,$OCC,SDC" >> "$PLAN_RESULT"
    fi
done

# =============================================
# Step 5: Summary
# =============================================
echo "" | tee -a "$OUTCOME"
echo "==================== LULESH FINAL RESULT ====================" | tee -a "$OUTCOME"

CRASH=$(grep -c ",CRASH$" "$PLAN_RESULT")
SDC=$(grep -c ",SDC$" "$PLAN_RESULT")
CORRECT=$(grep -c ",CORRECT$" "$PLAN_RESULT")
NOINJECT=$(grep -c ",NOINJECT$" "$PLAN_RESULT")
TOTAL=$((CRASH + SDC + CORRECT + NOINJECT))

echo "Total attempts        : $TOTAL"    | tee -a "$OUTCOME"
echo "CORRECT               : $CORRECT"  | tee -a "$OUTCOME"
echo "SDC                   : $SDC"      | tee -a "$OUTCOME"
echo "CRASH/DUE             : $CRASH"    | tee -a "$OUTCOME"
echo "NOINJECT (no FI hit)  : $NOINJECT" | tee -a "$OUTCOME"

# 只在有实际注入( CORRECT + SDC )里计算 SDC rate
echo "SDC rate (injected only) : $(echo "scale=4; if(($SDC+$CORRECT)>0) $SDC*100/($SDC+$CORRECT) else 0" | bc)%" | tee -a "$OUTCOME"

echo "All done! Results in $PLAN_RESULT and $OUTCOME"
echo "No golden file saved on disk. All 6 physical metrics strictly verified."
exit 0

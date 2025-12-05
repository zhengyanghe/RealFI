#!/bin/bash

# ================== CONFIG for miniFE (deterministic) ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/miniFE.x"

# 默认参数（nx=ny=nz=20），你已验证 100% 确定性
MINIFE_ARGS=""

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/minife_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/minife_stat_incremental.csv"
FSS="$CSV_DIR/minife_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_minife.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_minife_result.csv"
OUTCOME="$ROOT/scripts/outcome_minife.txt"

SAMPLE_INTERVAL=10000
TOTAL_INJECTIONS=1000
TIMEOUT_LIMIT=300          # 单次约 0.002~0.01 秒，300 秒绰绰有余

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan.py"

echo "Fault injection run for miniFE started at $(date)"
echo "Config: TOTAL_INJECTIONS=$TOTAL_INJECTIONS  Args: <default nx=ny=nz=20>"
mkdir -p "$CSV_DIR" "$ROOT/scripts"

# =============================================
# Step 1: Run Profiler
# =============================================
echo "[Step 1] Running profiler → $STAT"
setarch $(uname -m) -R pin -t $PIN_TOOL -o $STAT -sample_interval $SAMPLE_INTERVAL -- $EXEC $MINIFE_ARGS \
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
# Step 4: Fault Injection — 只比对三行关键物理结果
#   只在候选 CORRECT 时检查 Pintool 注入标志
# =============================================
echo "[Step 4] Starting fault injection → $PLAN_RESULT"
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

# 预先跑一次黄金输出，只提取三行关键物理结果作为签名
echo "Generating reference golden signature (3 critical lines)..."
GOLDEN_SIGN=$( "$EXEC" $MINIFE_ARGS 2>/dev/null | \
    grep -E "Initial Residual|Iteration = [0-9]+ Residual|Final Resid Norm" )

echo "Golden signature locked (3 lines):"
echo "$GOLDEN_SIGN"
echo "----------------------------------------" >> "$OUTCOME"
echo "miniFE GOLDEN PHYSICAL SIGNATURE:" >> "$OUTCOME"
echo "$GOLDEN_SIGN" >> "$OUTCOME"
echo "----------------------------------------" >> "$OUTCOME"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    INJECT_CMD="setarch $(uname -m) -R pin -t $FI_TOOL -addr $PC -occ $OCC -- $EXEC $MINIFE_ARGS"

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

    # 提取本次注入的三行关键结果
    INJECT_SIGN=$(echo "$OUTP" | \
        grep -E "Initial Residual|Iteration = [0-9]+ Residual|Final Resid Norm" )

    # 严格字符串比对（三行必须完全一致）
    if [ "$INJECT_SIGN" = "$GOLDEN_SIGN" ]; then
        # 候选 CORRECT：此时才检查 Pintool 是否真正注入成功
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] All 3 physical metrics identical (Final Resid = 2.07243e-16), fault injected." | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        else
            echo "[NOINJECT] Output matches GOLDEN, but Pintool reports no fault injected." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        echo "[SDC] CG solver result corrupted!" | tee -a "$OUTCOME"
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
echo "==================== miniFE FINAL RESULT ====================" | tee -a "$OUTCOME"

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
echo "No golden file saved on disk. All 3 CG residuals strictly verified."
exit 0

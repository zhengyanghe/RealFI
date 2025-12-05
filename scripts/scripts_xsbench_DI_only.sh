#!/bin/bash

# ================== CONFIG for XSBench (small, deterministic) ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/XSBench"

# 100% 确定性参数（你验证过多次 checksum = 941535）
XSB_ARGS="-s small -t 1"

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/xsbench_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/xsbench_stat_incremental.csv"
FSS="$CSV_DIR/xsbench_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_xsbench_DI_only.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_xsbench_DI_only_result.csv"
OUTCOME="$ROOT/scripts/outcome_xsbench_DI_only.txt"

SAMPLE_INTERVAL=1000000
TOTAL_INJECTIONS=1000
TIMEOUT_LIMIT=300          # 单次 14~16 秒，300 秒足够

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan_DI_only.py"

echo "Fault injection run for XSBench (small, deterministic) started at $(date)"
echo "Config: TOTAL_INJECTIONS=$TOTAL_INJECTIONS  Args: $XSB_ARGS"
mkdir -p "$CSV_DIR" "$ROOT/scripts"


echo "[Step 3] Generating injection plan → $PLAN"
python3 "$PLAN_PY" "$STAT" "$TOTAL_INJECTIONS" "$PLAN" || exit 1
echo "Plan saved to $PLAN"

# =============================================
# Step 4: Fault Injection — 精准判定 SDC/CRASH/NOINJECT
# =============================================
echo "[Step 4] Starting fault injection → $PLAN_RESULT"
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

# 预先跑一次黄金输出（只保留非时间行）
echo "Generating reference golden signature (excluding time-related lines)..."
GOLDEN_SIGN=$( "$EXEC" $XSB_ARGS 2>/dev/null | grep -v "Runtime:" | grep -v "Lookups/s:" )

# 只取黄金的 checksum 那一行，用于之后的比较
GOLDEN_CHECK_LINE=$(echo "$GOLDEN_SIGN" | grep "Verification checksum")

echo "Golden signature locked (checksum must be 941535)"
echo "----------------------------------------" >> "$OUTCOME"
echo "XSBench GOLDEN SIGNATURE:" >> "$OUTCOME"
echo "$GOLDEN_SIGN" >> "$OUTCOME"
echo "----------------------------------------" >> "$OUTCOME"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    INJECT_CMD="setarch $(uname -m) -R pin -t $FI_TOOL -addr $PC -occ $OCC -- $EXEC $XSB_ARGS"

    # 带超时运行
    OUTP=$(timeout $TIMEOUT_LIMIT bash -c "$INJECT_CMD" 2>&1)
    RET=$?

    echo "$OUTP" >> "$OUTCOME"
    echo "----------------------------------------" >> "$OUTCOME"

    # ============ 精准 CRASH 判断 ============
    if [ $RET -eq 124 ]; then
        echo "[CRASH] timeout > ${TIMEOUT_LIMIT}s" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi

    # 只有真正的崩溃（如 segfault、abort）才算 CRASH
    if [ $RET -ge 128 ] || [[ "$OUTP" == *"Segmentation fault"* ]] || [[ "$OUTP" == *"Aborted"* ]] || [[ "$OUTP" == *"Illegal instruction"* ]]; then
        echo "[CRASH] process crashed (exit code $RET or segfault)" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi

    # ============ exit code 0 或 1 都继续比对 ============
    INJECT_SIGN=$(echo "$OUTP" | grep -v "Runtime:" | grep -v "Lookups/s:")

    # 只提取注入 run 的 checksum 行
    INJECT_CHECK_LINE=$(echo "$INJECT_SIGN" | grep "Verification checksum")

    # 如果 checksum 行缺失或者和 golden 不一样 → SDC
    if [ -z "$INJECT_CHECK_LINE" ] || [ "$INJECT_CHECK_LINE" != "$GOLDEN_CHECK_LINE" ]; then
        echo "[SDC] Output corrupted! (checksum changed or missing)" | tee -a "$OUTCOME"
        echo ">>> GOLDEN checksum line:" >> "$OUTCOME"
        echo "$GOLDEN_CHECK_LINE" >> "$OUTCOME"
        echo ">>> INJECTED checksum line:" >> "$OUTCOME"
        echo "$INJECT_CHECK_LINE" >> "$OUTCOME"
        echo "$PC,$OCC,SDC" >> "$PLAN_RESULT"
        continue
    fi

    # 走到这里说明：checksum 行和 golden 完全一样
    # 候选 CORRECT，此时才检查 Pintool 是否真正注入成功
    if echo "$OUTP" | grep -q "Successful termination: YES"; then
        echo "[CORRECT] Checksum matches golden (= 941535), fault injected." | tee -a "$OUTCOME"
        echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
    else
        echo "[NOINJECT] Checksum matches golden, but Pintool reports no fault injected." | tee -a "$OUTCOME"
        echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
    fi
done

# =============================================
# Step 5: Summary
# =============================================
echo "" | tee -a "$OUTCOME"
echo "==================== XSBench FINAL RESULT ====================" | tee -a "$OUTCOME"

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

echo "All done! XSBench SDC detection now uses ONLY the checksum line + Pintool injection marker."
exit 0

#!/bin/bash

# ================== CONFIG ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT_FIGURE="$ROOT/401.bzip2/data/test/input"

# 执行文件路径已修改为 bzip2
EXEC="$ROOT/401.bzip2/run/run_base_test_amd64-m64-gcc42-nn.0000/bzip2_base.amd64-m64-gcc42-nn $INPUT_FIGURE/dryer.jpg 4"

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/bzip_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/bzip_stat_incremental.csv"
FSS="$CSV_DIR/bzip_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_bzip_DI_only.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_bzip_DI_only_result.csv"
OUTCOME="$ROOT/scripts/outcome_bzip_DI_only.txt"

SAMPLE_INTERVAL=1000000
TOTAL_INJECTIONS=1000
TIMEOUT_LIMIT=100   # seconds

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan_DI_only.py"

echo "Fault injection run for bzip started at $(date)"
echo "Config: EXEC='$EXEC' SAMPLE_INTERVAL=$SAMPLE_INTERVAL TOTAL_INJECTIONS=$TOTAL_INJECTIONS TIMEOUT=${TIMEOUT_LIMIT}s"
echo ""

mkdir -p "$CSV_DIR"
mkdir -p "$ROOT/scripts"

# =============================================
# Step 3: Generate injection plan
# =============================================
echo "[Step 3] Generating injection plan"

CMD="python3 $PLAN_PY $STAT $TOTAL_INJECTIONS $PLAN"
echo "Command: $CMD"
$CMD || { echo "ERROR: Plan generation failed"; exit 1; }

echo "Plan saved to: $PLAN"
echo ""

# =============================================
# STEP 4: Fault Injection with timeout
#   只在候选 CORRECT 时检查 Pintool 注入标志
# =============================================
echo "[Step 4] Running fault injection"
echo "Saving results to $PLAN_RESULT and $OUTCOME"

echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    CMD="setarch $(uname -m) -R pin -t $FI_TOOL -addr $PC -occ $OCC -- $EXEC"

    OUTP=$(timeout -k 5s ${TIMEOUT_LIMIT}s bash -c "$CMD" 2>&1)
    RET=$?

    echo "$OUTP" >> "$OUTCOME"
    echo "----------------------------------------" >> "$OUTCOME"

    # -------- 超时 → CRASH --------
    if [ $RET -eq 124 ]; then
        echo "[CRASH] timeout > ${TIMEOUT_LIMIT}s" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi

    # -------- 其它非零退出码 → CRASH --------
    if [ $RET -ne 0 ]; then
        echo "[CRASH] exit code $RET" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi

    # ======= bzip2 判定逻辑 (自校验) =======
    # 退出码为 0：bzip2 完成，自身会输出 "compared correctly" 等校验信息
    if echo "$OUTP" | grep -q "compared correctly"; then
        # 候选 CORRECT：此时才检查 Pintool 是否真正注入成功
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] Successful exit and self-validation passed, fault injected." | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        else
            echo "[NOINJECT] Output self-validates, but Pintool reports no fault injected." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        # 退出码为 0，但未报告 'compared correctly' → 视为 SDC
        echo "[SDC] Exit 0, but self-validation FAILED or missing." | tee -a "$OUTCOME"
        echo "$PC,$OCC,SDC" >> "$PLAN_RESULT"
    fi
done

# =============================================
# Step 5: Summary
# =============================================
echo "" | tee -a "$OUTCOME"
echo "==================== FINAL ====================" | tee -a "$OUTCOME"

CRASH_COUNT=$(tail -n +2 "$PLAN_RESULT" | grep -c ",CRASH$")
SDC_COUNT=$(tail -n +2 "$PLAN_RESULT" | grep -c ",SDC$")
CORRECT_COUNT=$(tail -n +2 "$PLAN_RESULT" | grep -c ",CORRECT$")
NOINJECT_COUNT=$(tail -n +2 "$PLAN_RESULT" | grep -c ",NOINJECT$")

TOTAL_RUNS=$((CRASH_COUNT + SDC_COUNT + CORRECT_COUNT + NOINJECT_COUNT))

echo "Total Attempts      : $TOTAL_RUNS"      | tee -a "$OUTCOME"
echo "CORRECT             : $CORRECT_COUNT"   | tee -a "$OUTCOME"
echo "SDC                 : $SDC_COUNT"       | tee -a "$OUTCOME"
echo "CRASH               : $CRASH_COUNT"     | tee -a "$OUTCOME"
echo "NOINJECT (no FI hit): $NOINJECT_COUNT"  | tee -a "$OUTCOME"

# 只在有实际注入 (CORRECT + SDC) 里计算 SDC rate
echo "SDC rate (injected only) : $(echo "scale=4; if(($SDC_COUNT+$CORRECT_COUNT)>0) $SDC_COUNT*100/($SDC_COUNT+$CORRECT_COUNT) else 0" | bc)%" | tee -a "$OUTCOME"

exit 0

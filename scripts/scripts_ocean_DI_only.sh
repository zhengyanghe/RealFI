#!/bin/bash

# ================== CONFIG ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

EXEC_BIN="$ROOT/OCEAN"     # 程序本体
EXEC_ARGS="-o"             # 参数单独放

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/ocean_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/ocean_stat_incremental.csv"
FSS="$CSV_DIR/ocean_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_ocean_DI_only.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_ocean_DI_only_result.csv"

OUTCOME="$ROOT/scripts/outcome_ocean_DI_only.txt"

SAMPLE_INTERVAL=1000
TOTAL_INJECTIONS=1000
TIMEOUT_LIMIT=60   # seconds

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan_DI_only.py"

ARCH="$(uname -m)"

echo "Fault injection run for OCEAN started at $(date)"
echo "Config: EXEC='$EXEC_BIN $EXEC_ARGS' SAMPLE_INTERVAL=$SAMPLE_INTERVAL TOTAL_INJECTIONS=$TOTAL_INJECTIONS TIMEOUT=${TIMEOUT_LIMIT}s"
echo ""

mkdir -p "$CSV_DIR"
mkdir -p "$ROOT/scripts"


# =============================================
# Step 3: Generate injection plan
# =============================================
echo "[Step 3] Generating injection plan"

python3 "$PLAN_PY" "$STAT" "$TOTAL_INJECTIONS" "$PLAN" || { echo "ERROR: Plan generation failed"; exit 1; }

echo "Plan saved to: $PLAN"
echo ""

# =============================================
# STEP 4: Fault Injection with timeout
#   多状态：CRASH / SDC / CORRECT / NOINJECT
#   只在候选 CORRECT 时检查 Pintool 的 Successful termination: YES/NO
# =============================================
echo "[Step 4] Running fault injection"
echo "Saving results to $PLAN_RESULT and $OUTCOME"

echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

# ======= 基准结果 MULTIGRID OUTPUTS =======
BASE_OUTPUT=$("$EXEC_BIN" $EXEC_ARGS 2>/dev/null)
BASE_LINES=$(echo "$BASE_OUTPUT" | sed -n '/MULTIGRID OUTPUTS/,/PROCESS STATISTICS/p' | grep "iter")

echo "[Base] Extracted $(echo "$BASE_LINES" | wc -l) multigrid lines" | tee -a "$OUTCOME"
echo "----------------------------------------" >> "$OUTCOME"
echo "OCEAN GOLDEN MULTIGRID LINES:" >> "$OUTCOME"
echo "$BASE_LINES" >> "$OUTCOME"
echo "----------------------------------------" >> "$OUTCOME"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    # 使用 timeout -k：
    #   - 先在 TIMEOUT_LIMIT 秒时发送 SIGTERM
    #   - 如仍未退出，5 秒后发送 SIGKILL，确保不会一直挂着
    OUTP=$(timeout -k 5s ${TIMEOUT_LIMIT}s \
           setarch "$ARCH" -R pin -t "$FI_TOOL" -addr "$PC" -occ "$OCC" -- \
           "$EXEC_BIN" $EXEC_ARGS 2>&1)
    RET=$?

    echo "$OUTP" >> "$OUTCOME"
    echo "----------------------------------------" >> "$OUTCOME"

    # -------- 超时 → CRASH --------
    if [ $RET -eq 124 ]; then
        echo "[CRASH] timeout > ${TIMEOUT_LIMIT}s" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi

    # -------- 其它非零 → CRASH --------
    if [ $RET -ne 0 ]; then
        echo "[CRASH] exit code $RET" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi

    # ======= 正常输出进行 SDC / CORRECT / NOINJECT 判定 =======
    FI_LINES=$(echo "$OUTP" | sed -n '/MULTIGRID OUTPUTS/,/PROCESS STATISTICS/p' | grep "iter")

    BASE_COUNT=$(echo "$BASE_LINES" | wc -l)
    FI_COUNT=$(echo "$FI_LINES" | wc -l)

    if [ "$BASE_COUNT" -ne "$FI_COUNT" ]; then
        echo "[SDC] line count mismatch" | tee -a "$OUTCOME"
        echo ">>> GOLDEN:" >> "$OUTCOME"
        echo "$BASE_LINES" >> "$OUTCOME"
        echo ">>> INJECTED:" >> "$OUTCOME"
        echo "$FI_LINES" >> "$OUTCOME"
        echo "$PC,$OCC,SDC" >> "$PLAN_RESULT"
        continue
    fi

    if diff <(echo "$BASE_LINES") <(echo "$FI_LINES") >/dev/null; then
        # 候选 CORRECT：multigrid 输出完全一致，此时检查 Pintool 是否真的注入成功
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] Multigrid outputs identical, fault injected." | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        elif echo "$OUTP" | grep -q "Successful termination: NO"; then
            echo "[NOINJECT] Multigrid outputs identical, but FI did not hit (NO)." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        else
            echo "[NOINJECT] Multigrid outputs identical, but no YES/NO marker." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        echo "[SDC] Multigrid outputs differ." | tee -a "$OUTCOME"
        echo ">>> GOLDEN:" >> "$OUTCOME"
        echo "$BASE_LINES" >> "$OUTCOME"
        echo ">>> INJECTED:" >> "$OUTCOME"
        echo "$FI_LINES" >> "$OUTCOME"
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

# 只在真正发生注入 (CORRECT + SDC) 中计算 SDC rate
echo "SDC rate (injected only) : $(echo "scale=4; if(($SDC_COUNT+$CORRECT_COUNT)>0) $SDC_COUNT*100/($SDC_COUNT+$CORRECT_COUNT) else 0" | bc)%" | tee -a "$OUTCOME"

exit 0

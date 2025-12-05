#!/bin/bash

# ================== CONFIG for NPB SP Class S (100% deterministic) ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/sp.S.x"

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/sp_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/sp_stat_incremental.csv"
FSS="$CSV_DIR/sp_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_sp.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_sp_result.csv"
OUTCOME="$ROOT/scripts/outcome_sp.txt"

SAMPLE_INTERVAL=100000
TOTAL_INJECTIONS=1000
TIMEOUT_LIMIT=300          # 单次约 2.7~2.8 秒，300 秒绰绰有余

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan.py"

ARCH="$(uname -m)"

echo "Fault injection run for NPB SP Class S started at $(date)"
echo "Config: TOTAL_INJECTIONS=$TOTAL_INJECTIONS  Command: $EXEC"
mkdir -p "$CSV_DIR" "$ROOT/scripts"

# =============================================
# Step 1: Run Profiler
# =============================================
echo "[Step 1] Running profiler to $STAT"

# setarch "$ARCH" -R pin -t "$PIN_TOOL" -o "$STAT" -sample_interval "$SAMPLE_INTERVAL" -- \
#     "$EXEC" >/dev/null 2>&1

if [ $? -ne 0 ]; then
    echo "ERROR: Profiler failed"
    exit 1
fi
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
echo "[Step 3] Generating injection plan to $PLAN"
python3 "$PLAN_PY" "$FSS" "$TOTAL_INJECTIONS" "$PLAN" || exit 1
echo "Plan saved to $PLAN"

# =============================================
# Step 4: Fault Injection — 严格比对 10 行 RMS-norms + Verification Successful
# =============================================
echo "[Step 4] Starting fault injection to $PLAN_RESULT"
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

# 预先跑一次黄金输出，只提取全部验证关键行（共 14 行）
echo "Generating reference golden signature (10 RMS-norms + Verification)..."
GOLDEN_SIGN=$("$EXEC" 2>/dev/null | \
    sed -n '/Verification being performed/,/Verification Successful/p' | \
    grep -E "accuracy setting|Comparison of RMS-norms| [0-9] [0-9]\.[0-9]+E[+-][0-9]+|Verification Successful")

echo "Golden signature locked (14 critical verification lines):"
echo "$GOLDEN_SIGN"
echo "----------------------------------------" >> "$OUTCOME"
echo "NPB SP Class S GOLDEN VERIFICATION SIGNATURE:" >> "$OUTCOME"
echo "$GOLDEN_SIGN" >> "$OUTCOME"
echo "----------------------------------------" >> "$OUTCOME"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    # 不用 bash -c，直接 timeout 包 setarch+pin+sp.S.x
    OUTP=$(timeout -k 5s ${TIMEOUT_LIMIT}s \
           setarch "$ARCH" -R pin -t "$FI_TOOL" -addr "$PC" -occ "$OCC" -- \
           "$EXEC" 2>&1)
    RET=$?

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

    # 提取本次注入的验证结果
    INJECT_SIGN=$(echo "$OUTP" | \
        sed -n '/Verification being performed/,/Verification Successful/p' | \
        grep -E "accuracy setting|Comparison of RMS-norms| [0-9] [0-9]\.[0-9]+E[+-][0-9]+|Verification Successful")

    # 严格字符串比对（任意一行不同即为 SDC）
    if [ "$INJECT_SIGN" = "$GOLDEN_SIGN" ]; then
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] Tuples/Checksum/Verification identical to golden, fault injected (YES)." | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        elif echo "$OUTP" | grep -q "Successful termination: NO"; then
            echo "[NOINJECT] Tuples/Checksum/Verification identical, but Pintool reports NO injection." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        else
            echo "[NOINJECT] Tuples/Checksum/Verification identical, but no YES/NO marker found." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        echo "[SDC] SP verification corrupted! (RMS-norms differ or not SUCCESSFUL)" | tee -a "$OUTCOME"
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
echo "==================== NPB SP Class S FINAL RESULT ====================" | tee -a "$OUTCOME"

CRASH=$(grep -c "CRASH" "$PLAN_RESULT")
SDC=$(grep -c "SDC" "$PLAN_RESULT")
CORRECT=$(grep -c "CORRECT" "$PLAN_RESULT")
TOTAL=$((CRASH + SDC + CORRECT))

echo "Total injections : $TOTAL" | tee -a "$OUTCOME"
echo "CORRECT          : $CORRECT" | tee -a "$OUTCOME"
echo "SDC              : $SDC"     | tee -a "$OUTCOME"
echo "CRASH/DUE        : $CRASH"   | tee -a "$OUTCOME"
echo "SDC rate         : $(echo "scale=4; if($TOTAL>0) $SDC*100/$TOTAL else 0" | bc)%" | tee -a "$OUTCOME"

echo "All done! Results in $PLAN_RESULT and $OUTCOME"
echo "14 verification lines (10 RMS-norms + SUCCESSFUL) strictly verified."
exit 0

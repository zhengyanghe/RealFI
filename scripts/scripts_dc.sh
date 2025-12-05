#!/bin/bash

# ================== CONFIG for NPB DC Class S (deterministic) ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/dc.S.x"                 # 使用 Class S 可执行文件
ARCH="$(uname -m)"

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/dc_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/dc_stat_incremental.csv"
FSS="$CSV_DIR/dc_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_dc.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_dc_result.csv"
OUTCOME="$ROOT/scripts/outcome_dc.txt"

SAMPLE_INTERVAL=10000
TOTAL_INJECTIONS=1000
TIMEOUT_LIMIT=300          # 单次很快，300 秒足够

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan.py"

echo "Fault injection run for NPB DC Class S started at $(date)"
echo "Config: TOTAL_INJECTIONS=$TOTAL_INJECTIONS  Command: $EXEC"
mkdir -p "$CSV_DIR" "$ROOT/scripts"

# =============================================
# Step 1: Run Profiler
# =============================================
echo "[Step 1] Running profiler → $STAT"
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
echo "[Step 3] Generating injection plan → $PLAN"
python3 "$PLAN_PY" "$FSS" "$TOTAL_INJECTIONS" "$PLAN" || exit 1
echo "Plan saved to $PLAN"

# =============================================
# Step 4: Fault Injection — 3 行核心结果 + YES/NO 判定
# =============================================
echo "[Step 4] Starting fault injection → $PLAN_RESULT"
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

# 预先跑一次黄金输出，只提取 3 行核心物理结果
echo "Generating reference golden signature (3 critical lines)..."
GOLDEN_SIGN=$("$EXEC" 2>/dev/null | \
    grep -E "Tuples Generated|Checksum =|Verification =")

echo "Golden signature locked:"
echo "$GOLDEN_SIGN"
echo "----------------------------------------" >> "$OUTCOME"
echo "NPB DC Class S GOLDEN CORE SIGNATURE:" >> "$OUTCOME"
echo "$GOLDEN_SIGN" >> "$OUTCOME"
echo "----------------------------------------" >> "$OUTCOME"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    # timeout 直接包 setarch+pin+dc
    OUTP=$(timeout "$TIMEOUT_LIMIT" \
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

    # 提取本次注入的 3 行核心结果
    INJECT_SIGN=$(echo "$OUTP" | grep -E "Tuples Generated|Checksum =|Verification =")

    # ---------- 输出与 GOLDEN 完全一致 → CORRECT / NOINJECT ----------
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
        # ---------- 输出和 GOLDEN 不同 → 直接 SDC ----------
        echo "[SDC] DC result corrupted! (Tuples/Checksum/Verification wrong)" | tee -a "$OUTCOME"
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
echo "==================== NPB DC Class S FINAL RESULT ====================" | tee -a "$OUTCOME"

CRASH=$(grep -c ",CRASH$" "$PLAN_RESULT")
SDC=$(grep -c ",SDC$" "$PLAN_RESULT")
CORRECT=$(grep -c ",CORRECT$" "$PLAN_RESULT")
NOINJECT=$(grep -c ",NOINJECT$" "$PLAN_RESULT")
TOTAL=$((CRASH + SDC + CORRECT + NOINJECT))

echo "Total injections      : $TOTAL"     | tee -a "$OUTCOME"
echo "CORRECT               : $CORRECT"   | tee -a "$OUTCOME"
echo "SDC                   : $SDC"       | tee -a "$OUTCOME"
echo "CRASH/DUE             : $CRASH"     | tee -a "$OUTCOME"
echo "NOINJECT (no FI hit)  : $NOINJECT"  | tee -a "$OUTCOME"
echo "SDC rate (injected only) : $(echo "scale=4; if(($SDC+$CORRECT)>0) $SDC*100/($SDC+$CORRECT) else 0" | bc)%" | tee -a "$OUTCOME"

echo "All done! Results in $PLAN_RESULT and $OUTCOME"
echo "3 core lines (Tuples Generated, Checksum, Verification) + YES/NO strictly used for classification."
exit 0

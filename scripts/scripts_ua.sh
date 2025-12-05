#!/bin/bash

# ================== CONFIG for NPB UA Class S (deterministic) ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/ua.S.x"
ARCH="$(uname -m)"

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/ua_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/ua_stat_incremental.csv"
FSS="$CSV_DIR/ua_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_ua.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_ua_result.csv"
OUTCOME="$ROOT/scripts/outcome_ua.txt"

SAMPLE_INTERVAL=1000000
TOTAL_INJECTIONS=1000
TIMEOUT_LIMIT=60          # 单次约 3~4 秒，60 秒足够

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan.py"

echo "Fault injection run for NPB UA Class S started at $(date)"
echo "Config: TOTAL_INJECTIONS=$TOTAL_INJECTIONS  Command: $EXEC"
mkdir -p "$CSV_DIR" "$ROOT/scripts"

# =============================================
# Step 1: Run Profiler
# =============================================
echo "[Step 1] Running profiler to $STAT"

setarch "$ARCH" -R pin -t "$PIN_TOOL" \
    -o "$STAT" -sample_interval "$SAMPLE_INTERVAL" -- \
    "$EXEC" >/dev/null 2>&1

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
# Step 4: Fault Injection — 严格比对所有动态网格 + 温度积分 + Verification
#             并区分 CORRECT / NOINJECT / SDC
# =============================================
echo "[Step 4] Starting fault injection to $PLAN_RESULT"
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

# 预先跑一次黄金输出，提取全部关键物理 + 验证行
echo "Generating reference golden signature (AMR steps + temperature integral + SUCCESSFUL)..."
GOLDEN_SIGN=$("$EXEC" 2>/dev/null | \
    grep -E "CG iterations:|Heat source radius:|Number of available threads:|Step [0-9]+:|Verification being performed|accuracy setting|Comparison of temperature integrals|Verification Successful")

echo "Golden signature locked (critical lines including all AMR steps):"
echo "$GOLDEN_SIGN"
echo "----------------------------------------" >> "$OUTCOME"
echo "NPB UA Class S GOLDEN PHYSICAL + VERIFICATION SIGNATURE:" >> "$OUTCOME"
echo "$GOLDEN_SIGN" >> "$OUTCOME"
echo "----------------------------------------" >> "$OUTCOME"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    # timeout 直接包 setarch + pin + ua.S.x
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

    # 提取本次注入的所有关键行
    INJECT_SIGN=$(echo "$OUTP" | \
        grep -E "CG iterations:|Heat source radius:|Number of available threads:|Step [0-9]+:|Verification being performed|accuracy setting|Comparison of temperature integrals|Verification Successful")

    # ======= 输出与 GOLDEN 完全一致 → CORRECT / NOINJECT =======
    if [ "$INJECT_SIGN" = "$GOLDEN_SIGN" ]; then
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] All AMR steps + temperature integral + verification identical to golden, fault injected (YES)." | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        elif echo "$OUTP" | grep -q "Successful termination: NO"; then
            echo "[NOINJECT] Output identical to golden, but Pintool reports NO injection." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        else
            echo "[NOINJECT] Output identical to golden, but no YES/NO marker found." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        # ======= 输出与 GOLDEN 不同 → 直接 SDC（不再看 YES/NO） =======
        echo "[SDC] UA result corrupted! (AMR step counts or temperature integral differ)" | tee -a "$OUTCOME"
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
echo "==================== NPB UA Class S FINAL RESULT ====================" | tee -a "$OUTCOME"

CRASH=$(grep -c ",CRASH$" "$PLAN_RESULT")
SDC=$(grep -c ",SDC$" "$PLAN_RESULT")
CORRECT=$(grep -c ",CORRECT$" "$PLAN_RESULT")
NOINJECT=$(grep -c ",NOINJECT$" "$PLAN_RESULT")
TOTAL=$((CRASH + SDC + CORRECT + NOINJECT))

echo "Total injections       : $TOTAL"    | tee -a "$OUTCOME"
echo "CORRECT                : $CORRECT"  | tee -a "$OUTCOME"
echo "SDC                    : $SDC"      | tee -a "$OUTCOME"
echo "CRASH/DUE              : $CRASH"    | tee -a "$OUTCOME"
echo "NOINJECT (no FI hit)   : $NOINJECT" | tee -a "$OUTCOME"
echo "SDC rate (injected only) : $(echo "scale=4; if(($SDC+$CORRECT)>0) $SDC*100/($SDC+$CORRECT) else 0" | bc)%" | tee -a "$OUTCOME"

echo "All done! Results in $PLAN_RESULT and $OUTCOME"
echo "Critical lines (AMR steps + temperature integral + SUCCESSFUL) + YES/NO strictly used for classification."
exit 0

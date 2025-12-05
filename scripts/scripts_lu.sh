#!/bin/bash

# ================== CONFIG for NPB LU Class W (100% deterministic) ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/lu.W.x"              # LU 可执行文件（无参数）
ARCH="$(uname -m)"

# 单线程、完全确定性的运行方式（如果你编译时已经禁用 OMP，这个只是兜底）
export OMP_NUM_THREADS=1

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/lu_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/lu_stat_incremental.csv"
FSS="$CSV_DIR/lu_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_lu.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_lu_result.csv"
OUTCOME="$ROOT/scripts/outcome_lu.txt"

SAMPLE_INTERVAL=1000000
TOTAL_INJECTIONS=1000
TIMEOUT_LIMIT=30          # 单次 LU + Pin 超过 30 秒就认为挂了

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan.py"

echo "Fault injection run for NPB LU Class W started at $(date)"
echo "Config: TOTAL_INJECTIONS=$TOTAL_INJECTIONS  Command: OMP_NUM_THREADS=1 $EXEC"
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
# Step 4: Fault Injection — 严格比对 11 行 RMS-norms + surface integral
# =============================================
echo "[Step 4] Starting fault injection to $PLAN_RESULT"
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

# 预先跑一次黄金输出，提取全部验证关键行
echo "Generating reference golden signature (11 RMS-norms + surface integral + SUCCESSFUL)..."
GOLDEN_SIGN=$("$EXEC" 2>/dev/null | \
    sed -n '/Verification being performed/,/Verification Successful/p' | \
    grep -E "Verification|Accuracy setting|Comparison of RMS-norms|Comparison of surface integral| [0-9] [0-9]\.[0-9]+E[+-][0-9]+" )

echo "Golden signature locked (critical verification lines):"
echo "$GOLDEN_SIGN"
echo "----------------------------------------" >> "$OUTCOME"
echo "NPB LU Class W GOLDEN VERIFICATION SIGNATURE:" >> "$OUTCOME"
echo "$GOLDEN_SIGN" >> "$OUTCOME"
echo "----------------------------------------" >> "$OUTCOME"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    # 关键改动：timeout -k 5s，先 TERM 再 KILL，防止卡死不退出
    OUTP=$(timeout -k 5s "${TIMEOUT_LIMIT}s" \
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

    # ---------- 提取本次注入的验证结果 ----------
    INJECT_SIGN=$(echo "$OUTP" | \
        sed -n '/Verification being performed/,/Verification Successful/p' | \
        grep -E "Verification|Accuracy setting|Comparison of RMS-norms|Comparison of surface integral| [0-9] [0-9]\.[0-9]+E[+-][0-9]+" )

    # 先看是否与 GOLDEN 完全一致
    if [ "$INJECT_SIGN" = "$GOLDEN_SIGN" ]; then
        # 候选 CORRECT，此时检查 Pintool 的 YES/NO 标记
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] All RMS-norms + surface integral identical (Verification Successful) & fault injected." | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        elif echo "$OUTP" | grep -q "Successful termination: NO"; then
            echo "[NOINJECT] Output matches GOLDEN, but Pintool reports NO injection." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        else
            echo "[NOINJECT] Output matches GOLDEN, but no YES/NO marker found." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        # 不相等直接 SDC，不再判断是否注入成功（和你“本来的方法”一致）
        echo "[SDC] LU verification corrupted! (RMS-norms or surface integral differ)" | tee -a "$OUTCOME"
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
echo "==================== NPB LU Class W FINAL RESULT ====================" | tee -a "$OUTCOME"

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

# 只在真正发生注入 (CORRECT + SDC) 里计算 SDC rate
echo "SDC rate (injected only) : $(echo "scale=4; if(($SDC+$CORRECT)>0) $SDC*100/($SDC+$CORRECT) else 0" | bc)%" | tee -a "$OUTCOME"

echo "All done! Results in $PLAN_RESULT and $OUTCOME"
exit 0

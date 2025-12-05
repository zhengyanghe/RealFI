#!/bin/bash

# ================== CONFIG for NPB FT Class S (100% deterministic) ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/ft.S.x"

# 100% 确定性运行方式（用 env 设置 OMP，不再用 bash -c）
ARCH="$(uname -m)"

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/ft_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/ft_stat_incremental.csv"
FSS="$CSV_DIR/ft_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_ft_DI_only.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_ft_DI_only_result.csv"
OUTCOME="$ROOT/scripts/outcome_ft_DI_only.txt"

SAMPLE_INTERVAL=100000
TOTAL_INJECTIONS=1000
TIMEOUT_LIMIT=300          # 单次约 0.11~0.13 秒，300 秒绰绰有余

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan_DI_only.py"

echo "Fault injection run for NPB FT Class S started at $(date)"
echo "Config: TOTAL_INJECTIONS=$TOTAL_INJECTIONS $EXEC"
mkdir -p "$CSV_DIR" "$ROOT/scripts"


# =============================================
# Step 3: Generate injection plan
# =============================================
echo "[Step 3] Generating injection plan to $PLAN"
python3 "$PLAN_PY" "$STAT" "$TOTAL_INJECTIONS" "$PLAN" || exit 1
echo "Plan saved to $PLAN"

# =============================================
# Step 4: Fault Injection — 严格比对 6 步 FFT Checksum
# =============================================
echo "[Step 4] Starting fault injection to $PLAN_RESULT"
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

# 预先跑一次黄金输出，提取 6 行 Checksum + Verification 作为签名
echo "Generating reference golden signature (6-step FFT Checksum)..."
GOLDEN_SIGN=$( "$EXEC" 2>/dev/null | \
    grep -E "Iterations|T = [1-6] Checksum|Result verification successful|Verification = SUCCESSFUL")

echo "Golden signature locked (6 Checksum lines + verification):"
echo "$GOLDEN_SIGN"
echo "----------------------------------------" >> "$OUTCOME"
echo "NPB FT Class S GOLDEN FFT CHECKSUM SIGNATURE:" >> "$OUTCOME"
echo "$GOLDEN_SIGN" >> "$OUTCOME"
echo "----------------------------------------" >> "$OUTCOME"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    # 注入命令：直接用 timeout 包住 setarch+pin，避免 bash -c 嵌套
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

    # 提取本次注入的 FFT Checksum 签名
    INJECT_SIGN=$(echo "$OUTP" | \
        grep -E "Iterations|T = [1-6] Checksum|Result verification successful|Verification = SUCCESSFUL")

    # 严格字符串比对（任意一个 Checksum 不同或未 SUCCESSFUL → SDC）
    if [ "$INJECT_SIGN" = "$GOLDEN_SIGN" ]; then
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] All 6 FFT Checksums identical and verification successful." | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        elif echo "$OUTP" | grep -q "Successful termination: NO"; then
            echo "[NOINJECT] All 6 FFT Checksums identical, but Pintool reports NO injection." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        else
            echo "[NOINJECT] All 6 FFT Checksums identical, but no YES/NO marker found." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        echo "[SDC] FFT Checksum corrupted! (T=1~6 differ or verification failed)" | tee -a "$OUTCOME"
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
echo "==================== NPB FT Class S FINAL RESULT ====================" | tee -a "$OUTCOME"

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
echo "6-step FFT Checksum + Verification strictly verified."
exit 0

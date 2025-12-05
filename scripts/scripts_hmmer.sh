#!/bin/bash

# ================== CONFIG for 456.hmmer ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"        # RealFI 根目录

# hmmer 所在目录
HMMER_DIR="$ROOT/hmmer"

# 真实运行命令
EXEC="$HMMER_DIR/hmmer_base.amd64-m64-gcc42-nn --fixed 0     --mean 325     --num 5000     --sd 15     --seed 0     $HMMER_DIR/bombesin.hmm"

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/hmmer_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/hmmer_stat_incremental.csv"
FSS="$CSV_DIR/hmmer_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_hmmer.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_hmmer_result.csv"
OUTCOME="$ROOT/scripts/outcome_hmmer.txt"

SAMPLE_INTERVAL=10000
TOTAL_INJECTIONS=1000           # hmmer 单条也很快
TIMEOUT_LIMIT=120               # 正常 ~15-30 秒，保险给 120 秒

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan.py"

# 黄金数值（你给出的）
GOLDEN_MU_VAL="-5.885353"
GOLDEN_LAMBDA_VAL="0.627338"
GOLDEN_MAX_VAL="7.707000"

echo "Fault injection run for 456.hmmer started at $(date)"
echo "Config: TOTAL_INJECTIONS=$TOTAL_INJECTIONS TIMEOUT=${TIMEOUT_LIMIT}s"
echo ""

mkdir -p "$CSV_DIR" "$ROOT/scripts"

# =============================================
# Step 0: 可选黄金运行（只是日志用，不参与比较）
# =============================================
if [ ! -f "$ROOT/golden_hmmer.txt" ]; then
    echo "[Step 0] Running one golden execution (for logging only)..."
    GOLDEN_RUN=$($EXEC 2>/dev/null)
    echo "$GOLDEN_RUN" > "$ROOT/golden_hmmer.txt"
    echo "Golden sample saved to $ROOT/golden_hmmer.txt"
    head -20 "$ROOT/golden_hmmer.txt"
else
    echo "[Step 0] golden_hmmer.txt already exists (not used for comparison)."
fi
echo ""

# =============================================
# Step 1: Run Profiler（你现在关掉了也没关系）
# =============================================
echo "[Step 1] Running profiler → $STAT"
CMD="setarch $(uname -m) -R pin -t $PIN_TOOL -o $STAT -sample_interval $SAMPLE_INTERVAL -- $HMMER_DIR/hmmer_base.amd64-m64-gcc42-nn --fixed 0     --mean 325     --num 5000     --sd 15     --seed 0     $HMMER_DIR/bombesin.hmm"
echo "Command: $CMD"
# 如需重新 profile 再打开下一行：
# $CMD || { echo "ERROR: Profiler failed"; exit 1; }
echo "Profiler completed (skipped or success)."
echo ""

# =============================================
# Step 2: FSS Calculation
# =============================================
echo "[Step 2] Running FSS calculation"
python3 "$INCREMENTAL_STAT_PY" "$STAT" "$INCREMENTAL_STAT" || exit 1
python3 "$CALC_PY" "$INCREMENTAL_STAT" || exit 1
echo "FSS file: $FSS"
echo ""

# =============================================
# Step 3: Generate injection plan
# =============================================
echo "[Step 3] Generating injection plan → $PLAN"
python3 "$PLAN_PY" "$FSS" "$TOTAL_INJECTIONS" "$PLAN" || exit 1
echo "Plan saved to $PLAN"
echo ""

# =============================================
# Step 4: Fault Injection
#   判定逻辑：
#   1) CRASH: timeout 或 非 0 退出码
#   2) 取出 mu/lambda/max 的数值，以及是否存在行 "//"
#   3) 若三值都等于黄金并且存在 "//"：
#        且包含 "Successful termination: YES" → CORRECT
#        且包含 "Successful termination: NO"  → NOINJECT
#      否则 → SDC
# =============================================
echo "[Step 4] Starting fault injection → $PLAN_RESULT"
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    CMD="setarch $(uname -m) -R pin -t $FI_TOOL -addr $PC -occ $OCC -- $HMMER_DIR/hmmer_base.amd64-m64-gcc42-nn --fixed 0     --mean 325     --num 5000     --sd 15     --seed 0     $HMMER_DIR/bombesin.hmm"

    # 超时保护 + 完整捕获 stdout+stderr
    OUTP=$(timeout ${TIMEOUT_LIMIT}s bash -c "$CMD" 2>&1)
    RET=$?

    # 记录完整输出用于调试
    echo "$OUTP" >> "$OUTCOME"

    # ---------- Timeout → CRASH ----------
    if [ $RET -eq 124 ]; then
        echo "[CRASH] timeout > ${TIMEOUT_LIMIT}s" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi

    # ---------- 其他异常退出 → CRASH ----------
    if [ $RET -ne 0 ]; then
        echo "[CRASH] exit code $RET" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi

    # ---------- 提取 mu / lambda / max 数值 + 是否存在 // ----------
    MU_VAL=$(echo "$OUTP"      | awk '/^mu/{print $3}'     | head -n1)
    LAMBDA_VAL=$(echo "$OUTP"  | awk '/^lambda/{print $3}' | head -n1)
    MAX_VAL=$(echo "$OUTP"     | awk '/^max/{print $3}'    | head -n1)

    if echo "$OUTP" | grep -q '^//$'; then
        HAS_SLASH=1
    else
        HAS_SLASH=0
    fi

    SAME_STATS=0
    if [ "$MU_VAL" = "$GOLDEN_MU_VAL" ] && \
       [ "$LAMBDA_VAL" = "$GOLDEN_LAMBDA_VAL" ] && \
       [ "$MAX_VAL" = "$GOLDEN_MAX_VAL" ] && \
       [ $HAS_SLASH -eq 1 ]; then
        SAME_STATS=1
    fi

    if [ $SAME_STATS -eq 1 ]; then
        # 统计结果完全一致 → 看 Pintool 标志
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] mu/lambda/max + // all match golden, and FI activated." | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        elif echo "$OUTP" | grep -q "Successful termination: NO"; then
            echo "[NOINJECT] mu/lambda/max + // match golden, but FI not activated." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        else
            # 理论上不会出现，兜底当作 NOINJECT
            echo "[NOINJECT] Stats match golden but no YES/NO marker found." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        echo "[SDC] hmmer stats corrupted (mu/lambda/max or // differ)." | tee -a "$OUTCOME"
        echo "  GOLDEN mu     = $GOLDEN_MU_VAL,  observed = $MU_VAL"     >> "$OUTCOME"
        echo "  GOLDEN lambda = $GOLDEN_LAMBDA_VAL, observed = $LAMBDA_VAL" >> "$OUTCOME"
        echo "  GOLDEN max    = $GOLDEN_MAX_VAL,  observed = $MAX_VAL"   >> "$OUTCOME"
        echo "$PC,$OCC,SDC" >> "$PLAN_RESULT"
    fi
done

# =============================================
# Step 5: Summary
# =============================================
echo "" | tee -a "$OUTCOME"
echo "================== 456.hmmer FINAL RESULT ==================" | tee -a "$OUTCOME"

CRASH=$(grep -c ",CRASH$" "$PLAN_RESULT")
SDC=$(grep -c ",SDC$" "$PLAN_RESULT")
CORRECT=$(grep -c ",CORRECT$" "$PLAN_RESULT")
NOINJECT=$(grep -c ",NOINJECT$" "$PLAN_RESULT")
TOTAL=$((CRASH + SDC + CORRECT + NOINJECT))

echo "Total injections     : $TOTAL"      | tee -a "$OUTCOME"
echo "CORRECT              : $CORRECT"    | tee -a "$OUTCOME"
echo "SDC                  : $SDC"        | tee -a "$OUTCOME"
echo "CRASH/DUE            : $CRASH"      | tee -a "$OUTCOME"
echo "NOINJECT (no FI hit) : $NOINJECT"   | tee -a "$OUTCOME"

# SDC rate 只在真正发生注入 (CORRECT + SDC) 内计算
echo "SDC rate (injected only) : $(echo "scale=4; if(($SDC+$CORRECT)>0) $SDC*100/($SDC+$CORRECT) else 0" | bc)% " | tee -a "$OUTCOME"

echo "All done! Results in $PLAN_RESULT and $OUTCOME"
exit 0

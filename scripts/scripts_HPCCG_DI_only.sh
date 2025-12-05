#!/bin/bash

# ================== CONFIG for HPCCG ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/test_HPCCG"                       # 直接放在 RealFI 根目录

# HPCCG 确定性参数（你验证过多次残差完全一致）
HPCCG_ARGS="10 10 10"

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/hpccg_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/hpccg_stat_incremental.csv"
FSS="$CSV_DIR/hpccg_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_hpccg_DI_only.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_hpccg_DI_only_result.csv"
OUTCOME="$ROOT/scripts/outcome_hpccg_DI_only.txt"

SAMPLE_INTERVAL=1000
TOTAL_INJECTIONS=1000
TIMEOUT_LIMIT=300   # 单次最多 300 秒（10×10×10 很快，1 秒都不到）

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan_DI_only.py"

echo "Fault injection run for HPCCG started at $(date)"
echo "Config: TOTAL_INJECTIONS=$TOTAL_INJECTIONS  Input: $HPCCG_ARGS"
mkdir -p "$CSV_DIR" "$ROOT/scripts"


# =============================================
# Step 3: Generate injection plan
# =============================================
echo "[Step 3] Generating injection plan → $PLAN"
python3 "$PLAN_PY" "$STAT" "$TOTAL_INJECTIONS" "$PLAN" || exit 1
echo "Plan saved to $PLAN"

# =============================================
# Step 4: Fault Injection — 核心：只比对残差行，内存黄金
#   数值判定完全按原来的方法；
#   只在 Residual 完全一致时，用 YES/NO 区分 CORRECT / NOINJECT。
# =============================================
echo "[Step 4] Starting fault injection → $PLAN_RESULT"
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

# 预先跑一次黄金输出，只提取残差行（内存中保存）
echo "Generating reference golden residual lines (once)..."
GOLDEN_RESIDUAL=$( "$EXEC" $HPCCG_ARGS 2>/dev/null | \
    grep -E 'Initial Residual|Iteration = [0-9]+ Residual =' | \
    sed 's/^[ \t]*//' )   # 去掉行首空格，防止 diff 误判

echo "Reference golden ready ($(echo "$GOLDEN_RESIDUAL" | wc -l) lines)"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    INJECT_CMD="setarch $(uname -m) -R pin -t $FI_TOOL -addr $PC -occ $OCC -- $EXEC $HPCCG_ARGS"

    # 带超时运行注入（保留完整输出，用于 YES/NO + 残差）
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
        echo "[CRASH] exit code $RET" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi

    # 提取本次注入的残差行
    INJECT_RESIDUAL=$(echo "$OUTP" | \
        grep -E 'Initial Residual|Iteration = [0-9]+ Residual =' | \
        sed 's/^[ \t]*//')

    # ---------- 数值判定：完全按你原来的方法 ----------
    if [ "$INJECT_RESIDUAL" = "$GOLDEN_RESIDUAL" ]; then
        # 数值上完全一致 → 候选 CORRECT
        # 现在再看 Pintool 注入标记：
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] Residuals identical, FI activated (YES)." | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        elif echo "$OUTP" | grep -q "Successful termination: NO"; then
            echo "[NOINJECT] Residuals identical, but FI did not hit (NO)." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        else
            # 理论上应该有 YES 或 NO，这里兜底：数值 correct 但没有标记 → 当 NOINJECT
            echo "[NOINJECT] Residuals identical, but no YES/NO marker found." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        echo "[SDC] Residual differs from golden!" | tee -a "$OUTCOME"
        # 可选：打印差异
        echo ">>> GOLDEN:" >> "$OUTCOME"
        echo "$GOLDEN_RESIDUAL" >> "$OUTCOME"
        echo ">>> INJECTED:" >> "$OUTCOME"
        echo "$INJECT_RESIDUAL" >> "$OUTCOME"
        echo "$PC,$OCC,SDC" >> "$PLAN_RESULT"
    fi
done

# =============================================
# Step 5: Summary
# =============================================
echo "" | tee -a "$OUTCOME"
echo "==================== HPCCG FINAL RESULT ====================" | tee -a "$OUTCOME"

CRASH=$(grep -c ",CRASH$" "$PLAN_RESULT")
SDC=$(grep -c ",SDC$" "$PLAN_RESULT")
CORRECT=$(grep -c ",CORRECT$" "$PLAN_RESULT")
NOINJECT=$(grep -c ",NOINJECT$" "$PLAN_RESULT")
TOTAL=$((CRASH + SDC + CORRECT + NOINJECT))

echo "Total injections     : $TOTAL"     | tee -a "$OUTCOME"
echo "CORRECT              : $CORRECT"   | tee -a "$OUTCOME"
echo "SDC                  : $SDC"       | tee -a "$OUTCOME"
echo "CRASH/DUE            : $CRASH"     | tee -a "$OUTCOME"
echo "NOINJECT (no FI hit) : $NOINJECT"  | tee -a "$OUTCOME"

# 只在真正发生注入 (CORRECT + SDC) 内计算 SDC rate
echo "SDC rate (injected only) : $(echo "scale=4; if(($SDC+$CORRECT)>0) $SDC*100/($SDC+$CORRECT) else 0" | bc)%" | tee -a "$OUTCOME"

echo "All done! Results in $PLAN_RESULT and $OUTCOME"
echo "No golden file saved on disk."
exit 0

#!/bin/bash

# ================== CONFIG for 462.libquantum ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"        # RealFI 项目根目录

# libquantum 可执行文件和参数
EXEC="$ROOT/libquantum_base.amd64-m64-gcc42-nn 33 5"

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"   # 如果你已经统一用 faultinjection.so，可以把这里改掉

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/libquantum_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/libquantum_stat_incremental.csv"
FSS="$CSV_DIR/libquantum_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_libquantum.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_libquantum_result.csv"
OUTCOME="$ROOT/scripts/outcome_libquantum.txt"

# 黄金输出文件（程序本身的输出，不含 Pintool YES/NO）
GOLDEN_OUTPUT="$ROOT/golden_libquantum.txt"

SAMPLE_INTERVAL=10000
TOTAL_INJECTIONS=1000          # libquantum 极快，跑几万次都没问题
TIMEOUT_LIMIT=30               # 正常只需 0.01 秒，30 秒足够

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan.py"

echo "Fault injection run for 462.libquantum started at $(date)"
echo "Config: TOTAL_INJECTIONS=$TOTAL_INJECTIONS TIMEOUT=${TIMEOUT_LIMIT}s"
echo ""

mkdir -p "$CSV_DIR" "$ROOT/scripts"

# =============================================
# Step 0: 生成黄金输出（只生成一次）
#   注意：这里是“本来的方法”——直接保存程序完整输出（6 行）
# =============================================
if [ ! -f "$GOLDEN_OUTPUT" ]; then
    echo "[Step 0] Generating golden output..."
    GOLDEN_RUN=$($EXEC 2>/dev/null)
    echo "$GOLDEN_RUN" > "$GOLDEN_OUTPUT"
    echo "Golden output saved to $GOLDEN_OUTPUT:"
    cat "$GOLDEN_OUTPUT"
else
    echo "[Step 0] Golden output already exists: $GOLDEN_OUTPUT"
fi
echo ""

# =============================================
# Step 1: Run Profiler
# =============================================
echo "[Step 1] Running profiler → $STAT"
CMD="setarch $(uname -m) -R pin -t $PIN_TOOL -o $STAT -sample_interval $SAMPLE_INTERVAL -- $ROOT/libquantum_base.amd64-m64-gcc42-nn 33 5"
echo "Command: $CMD"
$CMD || { echo "ERROR: Profiler failed"; exit 1; }
echo "Profiler completed"
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
#   1) Timeout / 非 0 退出 → CRASH
#   2) 把 Pintool 的 "Successful termination: XXX" 行过滤掉，只剩应用输出
#      应用输出 == GOLDEN_OUTPUT →
#        YES → CORRECT
#        NO  → NOINJECT
#      应用输出 != GOLDEN_OUTPUT → SDC
# =============================================
echo "[Step 4] Starting fault injection → $PLAN_RESULT"
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    CMD="setarch $(uname -m) -R pin -t $FI_TOOL -addr $PC -occ $OCC -- $ROOT/libquantum_base.amd64-m64-gcc42-nn 33 5"

    # 超时保护 + 捕获完整输出（包含 Pintool YES/NO）
    OUTP=$(timeout ${TIMEOUT_LIMIT}s bash -c "$CMD" 2>&1)
    RET=$?

    # 完整输出写入 outcome 方便 debug
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

    # ---------- 过滤掉 Pintool 的 Successful termination 行，只保留程序自身输出 ----------
    APP_OUTPUT=$(echo "$OUTP" | grep -v "Successful termination:")

    # “本来的方法”：用 6 行完整输出做严格比较
    if diff -u <(printf "%s\n" "$APP_OUTPUT") "$GOLDEN_OUTPUT" > /dev/null 2>&1; then
        # 应用输出和黄金完全一致，再根据 YES / NO 区分 CORRECT / NOINJECT
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] Output identical to golden, and FI activated." | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        elif echo "$OUTP" | grep -q "Successful termination: NO"; then
            echo "[NOINJECT] Output identical to golden, but FI not activated." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        else
            # 理论上应该总有 YES/NO，这里兜底当成 NOINJECT
            echo "[NOINJECT] Output identical, but no YES/NO marker found." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        echo "[SDC] Output differs from golden!" | tee -a "$OUTCOME"
        echo "$PC,$OCC,SDC" >> "$PLAN_RESULT"
    fi
done

# =============================================
# Step 5: Summary
# =============================================
echo "" | tee -a "$OUTCOME"
echo "================== 462.libquantum FINAL RESULT ==================" | tee -a "$OUTCOME"

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

# 只在实际有注入 (CORRECT + SDC) 内计算 SDC 率
echo "SDC rate (injected only) : $(echo "scale=4; if(($SDC+$CORRECT)>0) $SDC*100/($SDC+$CORRECT) else 0" | bc)% " | tee -a "$OUTCOME"

echo "All done! Results in $PLAN_RESULT and $OUTCOME"
exit 0

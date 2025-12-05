#!/bin/bash

# ================== CONFIG for 429.mcf ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"     # RealFI 根目录

# mcf 所在目录（你说和 OCEAN 同级）
MCF_DIR="$ROOT/mcf"

EXEC="$MCF_DIR/mcf_base.amd64-m64-gcc42-nn $MCF_DIR/inp.in"

# 黄金输出（无故障时第一次运行生成的 mcf.out）
GOLDEN_OUTPUT="$MCF_DIR/golden_mcf.out"

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/mcf_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/mcf_stat_incremental.csv"
FSS="$CSV_DIR/mcf_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_mcf_DI_only.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_mcf_DI_only_result.csv"
SCRIPTS_DIR="$ROOT/scripts"
OUTCOME="$ROOT/scripts/outcome_mcf_DI_only.txt"

SAMPLE_INTERVAL=100000
TOTAL_INJECTIONS=1000      # mcf 很快，随便跑几万都没问题
TIMEOUT_LIMIT=60           # 正常运行只要 0.1~0.3 秒，60 秒绰绰有余

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan_DI_only.py"

echo "Fault injection run for 429.mcf started at $(date)"
echo "Config: TOTAL_INJECTIONS=$TOTAL_INJECTIONS TIMEOUT=${TIMEOUT_LIMIT}s"
echo ""

mkdir -p "$CSV_DIR" "$ROOT/scripts"

# =============================================
# Step 0: 生成黄金输出（每次都重新生成，避免污染）
# =============================================
if [ ! -f "$GOLDEN_OUTPUT" ]; then
    echo "[Step 0] Generating golden mcf.out ..."
else
    echo "[Step 0] Golden output already exists: $GOLDEN_OUTPUT, regenerating..."
    rm -f "$GOLDEN_OUTPUT"
fi

echo "Running (no FI): $EXEC"
cd "$MCF_DIR"
rm -f mcf.out
./mcf_base.amd64-m64-gcc42-nn inp.in > /dev/null 2>&1
cp mcf.out "$GOLDEN_OUTPUT"
echo "Golden output saved to $GOLDEN_OUTPUT"
echo ""


# =============================================
# Step 3: Generate injection plan
# =============================================
echo "[Step 3] Generating injection plan → $PLAN"
python3 "$PLAN_PY" "$STAT" "$TOTAL_INJECTIONS" "$PLAN" || exit 1
echo "Plan saved to $PLAN"
echo ""

# =============================================
# Step 4: Fault Injection
#   CRASH / SDC 直接记为错误；
#   只有候选 CORRECT 时检查 Successful termination: YES → CORRECT / NOINJECT
# =============================================
echo "[Step 4] Starting fault injection (results → $PLAN_RESULT)"
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

cd "$SCRIPTS_DIR"
tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    # 每次注入前清理旧的 mcf.out（当前目录是 SCRIPTS_DIR）
    rm -f "$SCRIPTS_DIR/mcf.out"

    CMD="setarch $(uname -m) -R pin -t $FI_TOOL -addr $PC -occ $OCC -- $MCF_DIR/mcf_base.amd64-m64-gcc42-nn $MCF_DIR/inp.in"

    # 超时保护
    OUTP=$(timeout ${TIMEOUT_LIMIT}s bash -c "$CMD" 2>&1)
    RET=$?

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

    # ---------- 程序正常退出，检查 mcf.out ----------
    if [ ! -f "$SCRIPTS_DIR/mcf.out" ]; then
        echo "[CRASH] mcf.out not generated" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi

    if diff -q "$SCRIPTS_DIR/mcf.out" "$GOLDEN_OUTPUT" > /dev/null; then
        # 候选 CORRECT：输出完全一致，此时才检查 Pintool 是否真正注入成功
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] mcf.out identical to golden, fault injected." | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        else
            echo "[NOINJECT] mcf.out identical to golden, but Pintool reports no fault injected." | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        echo "[SDC] mcf.out differs from golden!" | tee -a "$OUTCOME"
        echo "$PC,$OCC,SDC" >> "$PLAN_RESULT"
    fi
done

# =============================================
# Step 5: Summary
# =============================================
echo "" | tee -a "$OUTCOME"
echo "================== 429.mcf FINAL RESULT ==================" | tee -a "$OUTCOME"

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
echo "SDC rate (injected only) : $(echo "scale=4; if(($SDC+$CORRECT)>0) $SDC*100/($SDC+$CORRECT) else 0" | bc)%" | tee -a "$OUTCOME"

echo "All done! Results in $PLAN_RESULT and $OUTCOME"
exit 0

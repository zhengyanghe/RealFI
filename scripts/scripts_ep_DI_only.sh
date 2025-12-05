#!/bin/bash

# ================== CONFIG for NPB EP Class W (100% deterministic) ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/ep.W.x"

# 100% 确定性运行方式（randi8 + 单线程 → 完全可重复）
EP_CMD="$EXEC"

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/ep_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/ep_stat_incremental.csv"
FSS="$CSV_DIR/ep_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_ep_DI_only.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_ep_result_DI_only.csv"
OUTCOME="$ROOT/scripts/outcome_ep_DI_only.txt"

SAMPLE_INTERVAL=100
TOTAL_INJECTIONS=1000
TIMEOUT_LIMIT=300          # 单次约 1.0~1.1 秒，300 秒绰绰有余

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan_DI_only.py"

# ★ 新增：bitflip.log 的路径（你的 FI 工具输出到 scripts 目录）
FI_LOG="$ROOT/scripts/bitflip.log"

echo "Fault injection run for NPB EP Class W started at $(date)"
echo "Config: TOTAL_INJECTIONS=$TOTAL_INJECTIONS  Command: $EP_CMD"
mkdir -p "$CSV_DIR" "$ROOT/scripts"

# =============================================
# Step 3: Generate injection plan
# =============================================
echo "[Step 3] Generating injection plan → $PLAN"
python3 "$PLAN_PY" "$STAT" "$TOTAL_INJECTIONS" "$PLAN" || exit 1
echo "Plan saved to $PLAN"

# =============================================
# Step 4: Fault Injection — 严格比对全部物理输出（Sums + 10个Counts + Verification）
# =============================================
cd "$ROOT/scripts"
echo "[Step 4] Starting fault injection → $PLAN_RESULT"

# 和 LU 一致：结果列只有 PC,OCC,RESULT，多一个 NOINJECT 类型
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

# 预先跑一次黄金输出，提取所有非时间关键行作为签名
echo "Generating reference golden signature (Sums + Counts + Verification)..."
GOLDEN_SIGN=$( bash -c "$EP_CMD" 2>/dev/null | \
    grep -A20 "EP Benchmark Results:" | \
    grep -v "CPU Time" | \
    grep -v "Time in seconds" | \
    grep -v "Mop/s" | \
    grep -E "N =|Gaussian Pairs|Sums|Counts:| [0-9] [0-9]+\.|Verification =|Class = W|Size =|Iterations =" )

echo "Golden signature locked (strict physical output):"
echo "$GOLDEN_SIGN"
echo "----------------------------------------" >> "$OUTCOME"
echo "NPB EP Class W GOLDEN PHYSICAL SIGNATURE:" >> "$OUTCOME"
echo "$GOLDEN_SIGN" >> "$OUTCOME"
echo "----------------------------------------" >> "$OUTCOME"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    INJECT_CMD="setarch $(uname -m) -R pin -t $FI_TOOL -addr $PC -occ $OCC -- $EXEC"

    OUTP=$(timeout $TIMEOUT_LIMIT bash -c "$INJECT_CMD" 2>&1)
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

    # 提取本次注入的物理签名
    INJECT_SIGN=$(echo "$OUTP" | \
        grep -A20 "EP Benchmark Results:" | \
        grep -v "CPU Time" | \
        grep -v "Time in seconds" | \
        grep -v "Mop/s" | \
        grep -E "N =|Gaussian Pairs|Sums|Counts:| [0-9] [0-9]+\.|Verification =|Class = W|Size =|Iterations =" )

    # 先比较签名是否和 GOLDEN 一致
    if [ "$INJECT_SIGN" = "$GOLDEN_SIGN" ]; then
        # ===== 只有候选 CORRECT 时，才检查是否真的注入成功 =====
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] All Sums and 10 Counts identical → Verification SUCCESSFUL" | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        else
            echo "[NOINJECT] Output matches GOLDEN, but Pintool reports no fault injected" | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        # ===== 一旦物理输出和 GOLDEN 不同，直接当作 SDC，不再检查注入成功 =====
        echo "[SDC] Gaussian random statistics corrupted! (Sums or Counts differ)" | tee -a "$OUTCOME"
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
echo "==================== NPB EP Class W FINAL RESULT ====================" | tee -a "$OUTCOME"

# 用带逗号+结尾的 grep，避免匹配到表头
CRASH=$(grep -c ",CRASH$" "$PLAN_RESULT")
SDC=$(grep -c ",SDC$" "$PLAN_RESULT")
CORRECT=$(grep -c ",CORRECT$" "$PLAN_RESULT")
NOINJECT=$(grep -c ",NOINJECT$" "$PLAN_RESULT")
TOTAL=$((CRASH + SDC + CORRECT + NOINJECT))

echo "Total attempts        : $TOTAL"    | tee -a "$OUTCOME"
echo "CORRECT               : $CORRECT"  | tee -a "$OUTCOME"
echo "SDC                   : $SDC"      | tee -a "$OUTCOME"
echo "CRASH/DUE             : $CRASH"    | tee -a "$OUTCOME"
echo "NOINJECT (no FI hit)  : $NOINJECT" | tee -a "$OUTCOME"

# 只在有实际注入( CORRECT + SDC )里计算 SDC rate
echo "SDC rate (injected only) : $(echo "scale=4; if(($SDC+$CORRECT)>0) $SDC*100/($SDC+$CORRECT) else 0" | bc)%" | tee -a "$OUTCOME"

echo "All done! Results in $PLAN_RESULT and $OUTCOME"
echo "All physical outputs (Sums, 10 Counts, Verification) strictly verified."
exit 0

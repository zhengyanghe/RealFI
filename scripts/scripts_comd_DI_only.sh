#!/bin/bash

# ================== CONFIG for CoMD ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMD_DIR="$ROOT/CoMD"
EXEC="$COMD_DIR/CoMD-serial"

# 确定性参数（你验证过多次物理结果完全一致）
COMD_ARGS="--potDir $COMD_DIR --potName Cu_u6.eam --potType funcfl --doeam \
           --nx 10 --ny 10 --nz 10 \
           --nSteps 100 --printRate 100 \
           --dt 1.0 --lat 3.52 --temp 300 --delta 0.0"

PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/faultinjection.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/comd_stat.csv"
INCREMENTAL_STAT="$CSV_DIR/comd_stat_incremental.csv"
FSS="$CSV_DIR/comd_stat_incremental_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan_comd_DI_only.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_comd_DI_only_result.csv"
OUTCOME="$ROOT/scripts/outcome_comd_DI_only.txt"

SAMPLE_INTERVAL=100000
TOTAL_INJECTIONS=1000
TIMEOUT_LIMIT=300   # 单次最多 300 秒

INCREMENTAL_STAT_PY="$ROOT/FSS_calculation/context.py"
CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan_DI_only.py"

mkdir -p "$CSV_DIR" "$ROOT/scripts"


# =============================================
# Step 3: Generate injection plan
# =============================================
echo "[Step 3] Generating injection plan → $PLAN"
python3 "$PLAN_PY" "$STAT" "$TOTAL_INJECTIONS" "$PLAN" || exit 1
echo "Plan saved to $PLAN"
echo ""

# =============================================
# Step 4: Fault Injection
#   逻辑：先用全局 GOLDEN_PHYSICAL 作为基准，
#   只有候选 CORRECT 时检查 Pintool 的 Successful termination: YES
# =============================================
echo "[Step 4] Starting fault injection → $PLAN_RESULT"
echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

# 预先跑一次黄金输出（只做一次，后面所有注入都和它比）
echo "Generating reference golden output (once)..."
GOLDEN_PHYSICAL=$( $EXEC $COMD_ARGS 2>/dev/null | \
    grep -E 'Initial energy|Final energy|eFinal/eInitial|Loop Time|Total Energy|Potential Energy|Kinetic Energy|Temperature' )
echo "Reference golden ready"

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    INJECT_CMD="setarch $(uname -m) -R pin -t $FI_TOOL -addr $PC -occ $OCC -- $EXEC $COMD_ARGS"

    # 带超时的注入运行
    OUTP=$(timeout $TIMEOUT_LIMIT bash -c "$INJECT_CMD" 2>&1)
    RET=$?

    echo "$OUTP" >> "$OUTCOME"
    echo "----------------------------------------" >> "$OUTCOME"

    # ===== CRASH 判断 =====
    if [ $RET -eq 124 ]; then
        echo "[CRASH] timeout" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi
    if [ $RET -ne 0 ]; then
        echo "[CRASH] exit code $RET" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi

    # 提取本次注入的物理行
    INJECT_PHYSICAL=$(echo "$OUTP" | \
        grep -E 'Initial energy|Final energy|eFinal/eInitial|Loop Time|Total Energy|Potential Energy|Kinetic Energy|Temperature')

    # ===== 和黄金进行严格比对 =====
    if [ "$INJECT_PHYSICAL" = "$GOLDEN_PHYSICAL" ]; then
        # 候选 CORRECT，此时才检查 Pintool 是否真正注入成功
        if echo "$OUTP" | grep -q "Successful termination: YES"; then
            echo "[CORRECT] Physical quantities identical to golden run" | tee -a "$OUTCOME"
            echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
        else
            echo "[NOINJECT] Output matches GOLDEN, but Pintool reports no fault injected" | tee -a "$OUTCOME"
            echo "$PC,$OCC,NOINJECT" >> "$PLAN_RESULT"
        fi
    else
        # 物理输出不同 → 直接 SDC，无需检查是否注入成功
        echo "[SDC] Physical output differs from golden!" | tee -a "$OUTCOME"
        echo ">>> GOLDEN:" >> "$OUTCOME"
        echo "$GOLDEN_PHYSICAL" >> "$OUTCOME"
        echo ">>> INJECTED:" >> "$OUTCOME"
        echo "$INJECT_PHYSICAL" >> "$OUTCOME"
        echo "$PC,$OCC,SDC" >> "$PLAN_RESULT"
    fi
done

# =============================================
# Step 5: Summary
# =============================================
echo "==================== CoMD FINAL RESULT ====================" | tee -a "$OUTCOME"

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

echo "All done! No golden file left on disk."
exit 0

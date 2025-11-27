#!/bin/bash

# ================== CONFIG ===================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

EXEC="$ROOT/simple_test"
PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/bit_flippers.so"

CSV_DIR="$ROOT/csv_file"
STAT="$CSV_DIR/stat.csv"
FSS="$CSV_DIR/stat_FSS_Score.csv"
PLAN="$ROOT/scripts/injection_plan.csv"
PLAN_RESULT="$ROOT/scripts/injection_plan_with_result.csv"

OUTCOME="$ROOT/scripts/outcome.txt"

SAMPLE_INTERVAL=1000
TOTAL_INJECTIONS=1000

CALC_PY="$ROOT/FSS_calculation/calculate.py"
PLAN_PY="$ROOT/scripts/generate_injection_plan.py"

echo "Fault injection run started at $(date)"
echo "Config: EXEC='$EXEC' SAMPLE_INTERVAL=$SAMPLE_INTERVAL TOTAL_INJECTIONS=$TOTAL_INJECTIONS"
echo ""

mkdir -p "$CSV_DIR"
mkdir -p "$ROOT/scripts"

# =============================================
# Step 1: Run Profiler
# =============================================
echo "[Step 1] Running profiler to produce: $STAT"

CMD="setarch $(uname -m) -R pin -t $PIN_TOOL -o $STAT -sample_interval $SAMPLE_INTERVAL -- $EXEC"
echo "Command: $CMD"

$CMD
if [ $? -ne 0 ]; then
    echo "ERROR: Profiler failed."
    exit 1
fi

echo "Profiler completed, stat.csv at $STAT"
echo ""

# =============================================
# Step 2: Run FSS Calculation
# =============================================
echo "[Step 2] Running FSS calculation"

CMD="python3 $CALC_PY $STAT"
echo "Command: $CMD"

$CMD
if [ $? -ne 0 ]; then
    echo "ERROR: FSS calculation failed."
    exit 1
fi

echo "FSS file generated: $FSS"
echo ""

# =============================================
# Step 3: Generate injection plan
# =============================================
echo "[Step 3] Generating injection plan (TOTAL_INJECTIONS=$TOTAL_INJECTIONS)"

CMD="python3 $PLAN_PY $FSS $TOTAL_INJECTIONS $PLAN"
echo "Command: $CMD"

$CMD
if [ $? -ne 0 ]; then
    echo "ERROR: injection plan generation failed."
    exit 1
fi

echo "Injection plan saved to: $PLAN"
echo ""

# =============================================
# Step 4: Fault Injection (in this section, you need to modify the code to measure whether the output is correct !!!)
# =============================================
echo "[Step 4] Running fault injection for all entries in plan"
echo "Results will be saved to: $PLAN_RESULT and $OUTCOME"

echo "PC,OCC,RESULT" > "$PLAN_RESULT"
echo "" > "$OUTCOME"

EXPECTED=$($EXEC | grep -o '[0-9]\+' | tail -n 1)

tail -n +2 "$PLAN" | while IFS=',' read -r PC OCC || [ -n "$PC" ]; do
    echo "Injecting PC=$PC OCC=$OCC" | tee -a "$OUTCOME"

    CMD="setarch $(uname -m) -R pin -t $FI_TOOL -addr $PC -occ $OCC -- $EXEC"
    OUTP=$($CMD 2>&1)
    RET=$?

    echo "$OUTP" | tee -a "$OUTCOME"

    if [ $RET -ne 0 ]; then
        echo "[CRASH]" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CRASH" >> "$PLAN_RESULT"
        continue
    fi

    RESULT=$(echo "$OUTP" | grep -o '[0-9]\+' | tail -n 1)

    if [ "$RESULT" = "$EXPECTED" ]; then
        echo "[CORRECT]" | tee -a "$OUTCOME"
        echo "$PC,$OCC,CORRECT" >> "$PLAN_RESULT"
    else
        echo "[SDC]" | tee -a "$OUTCOME"
        echo "$PC,$OCC,SDC" >> "$PLAN_RESULT"
    fi

done

# =============================================
# Step 5: Post-Injection Result Analysis (New Section)
# =============================================
echo ""
echo "==================== FINAL ====================" | tee -a "$OUTCOME"
echo "Full results saved to $PLAN_RESULT" | tee -a "$OUTCOME"

# Statistics Calculation:
# - Exclude the first line of the results file (head -n 1)
# - Use grep -c to count the number of each result type
CRASH_COUNT=$(tail -n +2 "$PLAN_RESULT" | grep -c "CRASH")
SDC_COUNT=$(tail -n +2 "$PLAN_RESULT" | grep -c "SDC")
CORRECT_COUNT=$(tail -n +2 "$PLAN_RESULT" | grep -c "CORRECT")

# Calculate total injections (if the PLAN file is clean, you can directly use TOTAL_INJECTIONS)
TOTAL_RUNS=$((CRASH_COUNT + SDC_COUNT + CORRECT_COUNT))

# Output Summary
echo "Total Injections: $TOTAL_RUNS" | tee -a "$OUTCOME"
echo "SDC Count: $SDC_COUNT" | tee -a "$OUTCOME"
echo "CRASH Count: $CRASH_COUNT" | tee -a "$OUTCOME"
echo "CORRECT Count: $CORRECT_COUNT" | tee -a "$OUTCOME"

exit 0

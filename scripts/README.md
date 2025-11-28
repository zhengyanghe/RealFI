# Scripts Directory – One-Click Fault Injection Campaign

This folder contains everything needed to run a complete **Pin-based dynamic fault-injection experiment** using the FSS (Fault Site Scoring) methodology.

## One-Click Usage

```bash
cd /path/to/your/project/scripts
./scripts.sh
```

That’s it! The script will automatically:

1. Run the profiler → csv_file/stat.csv
2. Initial data processing -> csv_file/stat_incremental.csv
3. Compute FSS scores → csv_file/stat_incremental_FSS_Score.csv
4. Generate an injection plan (TOTAL_INJECTIONS=100 by default)
5. Perform all fault injections
6. Classify every injection as **CORRECT / SDC / CRASH**
7. Print a final summary

All logs and results are saved inside this scripts/ folder.

## Files in this directory

| File                           | Description                                                  |
| ------------------------------ | ------------------------------------------------------------ |
| scripts.sh                     | Main driver script – just run this                           |
| generate_injection_plan.py     | Samples PCs according to FSS scores and generates injection_plan.csv |
| injection_plan.csv             | List of injections to perform (PC, OCC) – generated automatically |
| injection_plan_with_result.csv | Same as above + result column (CORRECT/SDC/CRASH) after the campaign |
| outcome.txt                    | Human-readable detailed log of every single injection        |
| bitflip.log                    | (optional) raw log produced by the Pin tool during injection |

## When you switch to a **new benchmark / test program**

You **must** update two places:

### 1. Configuration section (top of scripts.sh)

Bash

```
# ================== CONFIG ===================
ROOT="$$ (cd " $$(dirname "$0")/.." && pwd)"

EXEC="$ROOT/simple_test"           # ← CHANGE THIS: path to your new binary
PIN_TOOL="$ROOT/pin_tool/obj-intel64/profiler.so"
FI_TOOL="$ROOT/fault_injector/obj-intel64/bit_flippers.so"

SAMPLE_INTERVAL=100                # you may want to adjust
TOTAL_INJECTIONS=1000              # change number of injections here
```

Only the line with EXEC= normally needs to be modified.

### 2. Outcome classification logic (Step 4 in scripts.sh)

The current code assumes:

Bash

```
# Expected correct output = last number printed by the program
EXPECTED=$($EXEC | grep -o '[0-9]\+' | tail -n 1)

# During injection, we extract the same number and compare
RESULT=$(echo "$OUTP" | grep -o '[0-9]\+' | head -n 1)
```

If your new program has a **different way** of indicating correct execution, edit this block. Typical patterns and how to adapt them:

| Program output style                 | Recommended change                                           |
| ------------------------------------ | ------------------------------------------------------------ |
| Prints Result: 12345 on its own line | `EXPECTED=$($EXEC                                            |
| Exits with specific code on success  | Remove the RESULT=… extraction completely and only check $RET -eq 0 → CORRECT, else CRASH |
| Prints checksum / hash               | `EXPECTED=$($EXEC                                            |
| Multiple lines, correct marker OK    | `if echo "$OUTP"                                             |
| Silent program (only return code)    | Delete everything related to $RESULT and use only $RET for classification |

Just replace the three lines that compute EXPECTED and RESULT with logic that matches your benchmark.

### Optional parameters you may want to tweak

| Variable         | Meaning                   | Typical values |
| ---------------- | ------------------------- | -------------- |
| SAMPLE_INTERVAL  | Profiling granularity     | 50–500         |
| TOTAL_INJECTIONS | How many faults to inject | 500–10000      |

## Done!

After updating the two sections above, simply run ./scripts.sh again and you will get a complete fault-injection campaign for your new binary.

Happy injecting!
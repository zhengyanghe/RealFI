==========================================
RealFI - FSS Calculation Module
==========================================

This directory contains the scripts used to generate the
Feature Sensitivity Score (FSS) for instruction-level data.
The module operates in two major steps:

    (1) Convert cumulative profiler outputs into incremental values
    (2) Compute normalized features and the final FSS score

Both steps are described below.


------------------------------------------
1. context.py
------------------------------------------
Purpose:
    Convert cumulative instruction statistics into incremental values.

Input:
    - stat.csv (raw profiler output)

Output:
    - stat_incremental.csv
      Each row represents an independent per-sample instruction record,
      with:
          • incremental Execution_Count
          • incremental Avg_Latency
      rather than cumulative values.

Usage:
    python context.py <input_csv>

Notes:
    - This script must be run BEFORE computing FSS.
    - It ensures FSS calculation is based on truly independent samples.


------------------------------------------
2. calculate.py
------------------------------------------
Purpose:
    Compute the Feature Sensitivity Score (FSS) for each instruction.

Input:
    - stat_incremental.csv (produced by context.py)

Output:
    - stat_incremental_FSS_Score.csv
      Contains:
          • normalized Opcode, Bitwidth, Execution_Count, Avg_Latency
          • FSS score computed from the average of the normalized features

Usage:
    python calculate.py <input_csv>

Notes:
    - This is the main file used for all downstream analysis,
      including stability study, weight-sensitivity analysis,
      and feature correlation evaluation.


------------------------------------------
Overall Workflow
------------------------------------------
    1. Start from raw profiler output:
          stat.csv

    2. Generate incremental data:
          context.py → stat_incremental.csv

    3. Compute normalized FSS scores:
          calculate.py → stat_incremental_FSS_Score.csv

    4. Use stat_incremental_FSS_Score.csv for:
          - Sensitivity analysis
          - Weight stability heatmaps
          - Feature correlation analysis
          - Selecting top-k fault injection candidates


==========================================
End of README
==========================================



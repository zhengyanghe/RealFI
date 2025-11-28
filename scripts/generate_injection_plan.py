import pandas as pd
import numpy as np
import sys
from io import StringIO

if len(sys.argv) < 4:
    print("Usage: python generate_injection_plan.py stat_FSS_Score.csv EXEC_COUNT OUTPUT_PLAN.csv")
    exit(1)

fss_csv = sys.argv[1]
N = int(sys.argv[2])      # total injections
out_csv = sys.argv[3]

df = pd.read_csv(fss_csv)

# remove rows with NaN in 'PC' or 'Execution_Count_Cum'
df = df[df['PC'].notnull() & df['Execution_Count_Cum'].notnull()]

# ensure Execution_Count_Cum is numeric and convert to int
df['Execution_Count_Cum'] = df['Execution_Count_Cum'].astype(int)

# --- key modification: calculate Exec_Diff ---
# group by 'PC' and calculate difference for 'Execution_Count_Cum'
# shift(1) replaces each row's value with the previous row's value (within the current group).
# fillna(df['Execution_Count_Cum']) is used to handle the first row of each PC group,
# its difference is its own Execution_Count_Cum (because it starts from 0)
df['Previous_Exec_Count'] = df.groupby('PC')['Execution_Count_Cum'].shift(1).fillna(0).astype(int)

# calculate difference: current ExecCount minus previous ExecCount of the same PC
# This Exec_Diff represents the range of execution counts for the PC instance in this row
df['Exec_Diff'] = df['Execution_Count_Cum'] - df['Previous_Exec_Count']

# Check if the difference is greater than 0, if not, set it to 1 (to ensure a valid range)
df['Exec_Diff'] = df['Exec_Diff'].apply(lambda x: x if x > 0 else 1)

# normalize FSS Score
total_fss = df['FSS_Score'].sum()
df['Prob'] = df['FSS_Score'] / total_fss

# choose N PCs
chosen_indices = np.random.choice(
    df.index,
    size=N,
    replace=True,
    p=df['Prob']
)

plans = []
for idx in chosen_indices:
    row = df.loc[idx]
    pc = row['PC']
    exec_diff = row['Exec_Diff']  # use the new Exec_Diff

    # randomly choose occ in the range [1, Exec_Diff]
    # select an injection point within this Exec_Diff range
    occ = np.random.randint(1, exec_diff + 1)
    
    # the final OCC is the previous Execution_Count_Cum + occ
    # this is the absolute OCC relative to the entire program execution
    final_occ = row['Previous_Exec_Count'] + occ

    plans.append([pc, final_occ])

# --- write to CSV file, prevent trailing newline ---

# Note: Here we rename the columns to 'PC', 'ABS_OCC' (absolute occurrence count) to clarify it is an absolute value
plan_df = pd.DataFrame(plans, columns=['PC', 'OCC']) 

# 1. Convert DataFrame to CSV string
output = StringIO()
plan_df.to_csv(output, index=False, lineterminator='\n') 

# 2. Get string content
content = output.getvalue()
output.close()

# 3. Remove trailing newline
final_content = content.rstrip('\n')

# 4. Write the processed content to file
with open(out_csv, 'w', encoding='utf-8') as f:
    f.write(final_content)

print(f"Generated injection plan with {N} injections → {out_csv}")
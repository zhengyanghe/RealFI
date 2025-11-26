import pandas as pd
import numpy as np
import sys
import csv # 导入 csv 模块
from io import StringIO # 用于处理内存中的 CSV 数据

if len(sys.argv) < 4:
    print("Usage: python generate_injection_plan.py stat_FSS_Score.csv EXEC_COUNT OUTPUT_PLAN.csv")
    exit(1)

fss_csv = sys.argv[1]
N = int(sys.argv[2])      # total injections
out_csv = sys.argv[3]

df = pd.read_csv(fss_csv)

# Remove any row without PC or ExecCount
df = df[df['PC'].notnull() & df['Execution_Count'].notnull()]

# Normalize FSS Score
total_fss = df['FSS_Score'].sum()
df['Prob'] = df['FSS_Score'] / total_fss

# Choose N PCs based on probability
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
    exec_cnt = int(row['Execution_Count'])

    # Random choose occurrence
    occ = np.random.randint(1, exec_cnt + 1)

    plans.append([pc, occ])

# --- 关键修改：手动写入 CSV 文件以阻止末尾的换行符 ---

plan_df = pd.DataFrame(plans, columns=['PC', 'OCC'])

# 1. 将 DataFrame 转换为 CSV 字符串
# 使用 StringIO 将数据写入内存，并确保使用 lineterminator='\n'
output = StringIO()
plan_df.to_csv(output, index=False, lineterminator='\n') 

# 2. 获取字符串内容
content = output.getvalue()
output.close()

# 3. 移除末尾的换行符 (如果存在)
# content.rstrip('\n') 会移除字符串末尾的所有换行符
final_content = content.rstrip('\n')

# 4. 将处理后的内容写入文件
with open(out_csv, 'w', encoding='utf-8') as f:
    f.write(final_content)

print(f"Generated injection plan with {N} injections → {out_csv}")
# generate_injection_plan_v2.py
# 用法: python generate_injection_plan_v2.py input_trace.csv N output_plan.csv

import pandas as pd
import numpy as np
import sys
from io import StringIO

if len(sys.argv) != 4:
    print("Usage: python generate_injection_plan_v2.py <input_csv> <N> <output_csv>")
    print("    input_csv  : 包含 ID,PC,Opcode,Bitwidth,Execution_Count,... 的追踪文件")
    print("    N          : 要生成的注入数量")
    print("    output_csv : 输出的注入计划 (PC,OCC)")
    sys.exit(1)

input_csv  = sys.argv[1]
N          = int(sys.argv[2])
output_csv = sys.argv[3]

# 1. 读取文件
df = pd.read_csv(input_csv)

# 必须包含这些列
required_cols = ['PC', 'Execution_Count']
for col in required_cols:
    if col not in df.columns:
        print(f"错误：输入文件缺少列 '{col}'")
        sys.exit(1)

# 确保 Execution_Count 是整数
df['Execution_Count'] = pd.to_numeric(df['Execution_Count'], errors='coerce')
df = df.dropna(subset=['PC', 'Execution_Count'])
df['Execution_Count'] = df['Execution_Count'].astype(int)

# 2. 只保留每个 PC 的最后一次出现（即最终执行次数）
#    使用 drop_duplicates(keep='last') 或者 groupby + last()
df_last = df.sort_values(by=['PC', 'ID']).drop_duplicates(subset='PC', keep='last').copy()
# 或者等价写法：
# df_last = df.groupby('PC', as_index=False).last()

# 过滤掉 Execution_Count <= 0 的（避免概率为0或负数）
df_last = df_last[df_last['Execution_Count'] > 0]

if df_last.empty:
    print("错误：没有有效的 PC（Execution_Count > 0）")
    sys.exit(1)

# 3. 计算注入概率 ∝ Execution_Count
total_exec = df_last['Execution_Count'].sum()
df_last['Prob'] = df_last['Execution_Count'] / total_exec

# 4. 采样 N 次（允许重复注入同一个 PC）
chosen_indices = np.random.choice(
    df_last.index,
    size=N,
    replace=True,          # 允许同一个 PC 被多次选中
    p=df_last['Prob'].values
)

# 5. 为每一次采样生成 (PC, OCC)
plans = []
pc_to_count = df_last.set_index('PC')['Execution_Count'].to_dict()

for idx in chosen_indices:
    row = df_last.loc[idx]
    pc = row['PC']
    exec_cnt = pc_to_count[pc]                 # 该 PC 的总执行次数
    occ = np.random.randint(1, exec_cnt + 1)   # 随机在 1 ~ exec_cnt 之间选
    plans.append([pc, occ])

# 6. 保存为 CSV（无索引、无多余空行）
plan_df = pd.DataFrame(plans, columns=['PC', 'OCC'])

# 精确控制输出，不留末尾空行
output = StringIO()
plan_df.to_csv(output, index=False, lineterminator='\n')
content = output.getvalue().rstrip('\n')   # 去掉最后的换行符（如果有）
output.close()

with open(output_csv, 'w', encoding='utf-8', newline='\n') as f:
    f.write(content)

print(f"成功生成注入计划：{N} 条记录 → {output_csv}")
print(f"共 {len(df_last)} 个唯一 PC，总执行次数 = {total_exec:,}")
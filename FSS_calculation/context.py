import pandas as pd
import sys

if len(sys.argv) < 2:
    print("Usage: python update_incremental_stats.py <input_csv_file>")
    sys.exit(1)

input_file = sys.argv[1]
print(f"Reading data from: {input_file}")

# 自动生成输出文件名
output_file = input_file.replace(".csv", "_incremental.csv")
if output_file == input_file:
    output_file = input_file.replace(".", "_incremental.")

try:
    df = pd.read_csv(input_file)
except FileNotFoundError:
    print(f"Error: The file '{input_file}' was not found.")
    sys.exit(1)
except Exception as e:
    print(f"An error occurred while reading the file: {e}")
    sys.exit(1)

# 备份原始累计字段（如果你想保留的话）
df["Execution_Count_Cum"] = df["Execution_Count"]
df["Avg_Latency_Cum"] = df["Avg_Latency"]

# 确保按 PC 和 ID 排序（ID 是你说的 0,1,2,3...）
df = df.sort_values(["PC", "ID"]).reset_index(drop=True)

def make_incremental(group: pd.DataFrame) -> pd.DataFrame:
    """
    对同一个 PC 的多行记录，将 Execution_Count / Avg_Latency
    从“累计值”转换为“本段增量值”。
    """
    new_counts = []
    new_avg_lat = []

    prev_count = None
    prev_latency_sum = None  # 上一次的 (count * avg_latency)

    for _, row in group.iterrows():
        count_cum = row["Execution_Count"]
        avg_cum = row["Avg_Latency"]
        latency_sum_cum = count_cum * avg_cum

        if prev_count is None or count_cum <= prev_count:
            # 第一条记录，或者累计数异常（不递增），就直接当作“全量”
            delta_count = count_cum
            delta_latency_sum = latency_sum_cum
        else:
            # 正常情况：当前 - 上一次
            delta_count = count_cum - prev_count
            delta_latency_sum = latency_sum_cum - prev_latency_sum

        if delta_count <= 0:
            # 防止除零 / 负数，直接设为 0
            new_counts.append(0)
            new_avg_lat.append(0.0)
        else:
            new_counts.append(delta_count)
            new_avg_lat.append(delta_latency_sum / delta_count)

        prev_count = count_cum
        prev_latency_sum = latency_sum_cum

    group["Execution_Count"] = new_counts
    group["Avg_Latency"] = new_avg_lat
    return group

# 对每个 PC 单独做增量转换
df_updated = df.groupby("PC", group_keys=False).apply(make_incremental)

# 写回 CSV
df_updated.to_csv(output_file, index=False)
print(f"Incremental stats written to {output_file}")



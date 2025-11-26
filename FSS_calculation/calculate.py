import pandas as pd
from sklearn.preprocessing import MinMaxScaler
import sys # 引入 sys 模块

# ==============================================================
# 1. 处理命令行参数
# ==============================================================
if len(sys.argv) < 2:
    print("Usage: python your_script_name.py <input_csv_file>")
    sys.exit(1)

# 获取用户输入的第一个参数作为输入文件名
input_file = sys.argv[1]
print(f"Reading data from: {input_file}")

# 自动生成输出文件名 (例如：input.csv -> input_FSS_Score.csv)
output_file = input_file.replace(".csv", "_FSS_Score.csv")
if output_file == input_file:
    # 防止文件名替换失败，添加后缀
    output_file = input_file.replace(".", "_FSS_Score.") 

try:
    # 2. 读取数据 (使用参数)
    # 注意：为了避免读取 Pin Tool 报告末尾的总结行，我们只读取到第一个非数据行
    # 通常 Pin Tool 总结行以 '#' 或 '-' 开头，但这里假设输入文件已清洗干净，只读取数据。
    df = pd.read_csv(input_file)
except FileNotFoundError:
    print(f"Error: The file '{input_file}' was not found.")
    sys.exit(1)
except Exception as e:
    print(f"An error occurred while reading the file: {e}")
    sys.exit(1)

# ==============================================================
# 2.5. 关键修改：去重，只保留每个 PC 最后一次出现的行
# ==============================================================
print("Removing duplicate PCs and keeping the last (most cumulative) record...")
# 使用 drop_duplicates() 函数，以 'PC' 列为准，并保留最后出现的行 (keep='last')
df = df.drop_duplicates(subset=['PC'], keep='last').reset_index(drop=True)
print(f"Remaining unique static PCs: {len(df)}")


# 3. 映射 Opcode 为数值（示例，可根据你定义的语义权重进行替换）
opcode_map = {
    "ARITH": 3,
    "LOGIC": 2,
    "LOAD": 4,
    "STORE": 4,
    "BRANCH": 1,
    "FP_MUL": 5,
    "FP_DIV": 6,
    "OTHER": 0
}
df["Opcode_Num"] = df["Opcode"].map(opcode_map).fillna(0)

# 4. 准备归一化字段
features_to_normalize = ["Opcode_Num", "Bitwidth", "Execution_Count", "Avg_Latency"]

# 5. 归一化
scaler = MinMaxScaler()
# 注意：使用 .copy() 来避免 SettingWithCopyWarning
df_normalized = pd.DataFrame(
    scaler.fit_transform(df[features_to_normalize]), 
    columns=[f"{f}_Norm" for f in features_to_normalize]
)

# 6. 合并归一化结果
df = pd.concat([df.reset_index(drop=True), df_normalized.reset_index(drop=True)], axis=1)

# 7. 计算 FSS_Score：四个归一值的平均
df["FSS_Score"] = df_normalized.mean(axis=1)

# 8. 输出结果 (使用自动生成的输出文件名)
df.to_csv(output_file, index=False)
print(f"FSS scores written to {output_file}")
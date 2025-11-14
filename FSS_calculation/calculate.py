import pandas as pd
from sklearn.preprocessing import MinMaxScaler

# 1. 读取数据
df = pd.read_csv("CoMD.csv")

# 2. 映射 Opcode 为数值（示例，可根据你定义的语义权重进行替换）
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

# 3. 准备归一化字段
features_to_normalize = ["Opcode_Num", "Bitwidth", "Execution_Count", "Avg_Latency"]

# 4. 归一化
scaler = MinMaxScaler()
df_normalized = pd.DataFrame(scaler.fit_transform(df[features_to_normalize]), columns=[f"{f}_Norm" for f in features_to_normalize])

# 5. 合并归一化结果
df = pd.concat([df, df_normalized], axis=1)

# 6. 计算 FSS_Score：四个归一值的平均
df["FSS_Score"] = df_normalized.mean(axis=1)

# 7. 输出结果
df.to_csv("CoMD_FSS_Score.csv", index=False)
print("FSS scores written to CoMD_FSS_Score.csv")


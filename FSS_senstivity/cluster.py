import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
import sys

"""
FSS Stability Analysis (0.05 and 0.10 in one figure)
----------------------------------------------------
Usage:
    python fss_stability_two_ratios.py stat_incremental_FSS_Score.csv

Input:
    - input_csv: normalized + incremental FSS dataset with columns:
      ID, Opcode_Num_Norm, Bitwidth_Norm, Execution_Count_Norm, Avg_Latency_Norm

Output:
    - stability_results_0.05.csv
    - stability_results_0.10.csv
    - stability_heatmap_0.05_0.10.pdf
"""

# ---------------------------
# 1. Load arguments
# ---------------------------
if len(sys.argv) < 2:
    print("Usage: python fss_stability_two_ratios.py <input_csv>")
    sys.exit(1)

input_csv = sys.argv[1]
print(f"[INFO] Input File: {input_csv}")

# ---------------------------
# 2. Load CSV
# ---------------------------
df = pd.read_csv(input_csv)

required = [
    "ID",
    "Opcode_Num_Norm",
    "Bitwidth_Norm",
    "Execution_Count_Norm",
    "Avg_Latency_Norm"
]

for col in required:
    if col not in df.columns:
        raise KeyError(f"Column missing: {col}")

N = len(df)
print(f"[INFO] Total instructions = {N}")

# -------------------------------------------
# 3. Define weight models (semantic categories)
# -------------------------------------------
weight_models = {
    "A1_uniform":      [0.25, 0.25, 0.25, 0.25],
    "A2_opcode_down":  [0.10, 0.30, 0.30, 0.30],
    "A3_bitwidth_down":[0.30, 0.10, 0.30, 0.30],
    "A4_exec_down":    [0.30, 0.30, 0.10, 0.30],
    "A5_latency_down": [0.30, 0.30, 0.30, 0.10],

    "B1_structural":   [0.40, 0.40, 0.10, 0.10],
    "B2_behavioral":   [0.10, 0.10, 0.40, 0.40],
    "B3_mixed_time":   [0.40, 0.10, 0.10, 0.40],
    "B4_data_heavy":   [0.10, 0.40, 0.40, 0.10],

    "C1_only_opcode":  [1.0, 0.0, 0.0, 0.0],
    "C2_only_bitwidth":[0.0, 1.0, 0.0, 0.0],
    "C3_only_exec":    [0.0, 0.0, 1.0, 0.0],
    "C4_only_latency": [0.0, 0.0, 0.0, 1.0]
}

models = list(weight_models.keys())
M = len(models)

# 为坐标轴准备缩写标签
short_labels = {
    "A1_uniform": "A1",
    "A2_opcode_down": "A2",
    "A3_bitwidth_down": "A3",
    "A4_exec_down": "A4",
    "A5_latency_down": "A5",
    "B1_structural": "B1",
    "B2_behavioral": "B2",
    "B3_mixed_time": "B3",
    "B4_data_heavy": "B4",
    "C1_only_opcode": "C1",
    "C2_only_bitwidth": "C2",
    "C3_only_exec": "C3",
    "C4_only_latency": "C4",
}
xyticks = [short_labels[m] for m in models]

# -------------------------------------------
# 4. Helper: compute Jaccard matrix for a given ratio
# -------------------------------------------
def compute_jaccard_matrix(topk_ratio: float):
    N = len(df)
    K = max(1, int(N * topk_ratio))
    print(f"[INFO] Computing stability for ratio={topk_ratio}, Top-K={K}")

    # 计算各模型的 Top-K 集合
    topk_sets = {}
    for name, w in weight_models.items():
        df[f"FSS_{name}"] = (
            w[0] * df["Opcode_Num_Norm"] +
            w[1] * df["Bitwidth_Norm"] +
            w[2] * df["Execution_Count_Norm"] +
            w[3] * df["Avg_Latency_Norm"]
        )
        topk_df = df.nlargest(K, f"FSS_{name}")
        topk_sets[name] = set(topk_df["ID"])

    # 配对计算 Jaccard
    mat = np.ones((M, M))
    results = []
    idx = {m: i for i, m in enumerate(models)}

    for i in range(M):
        for j in range(i + 1, M):
            m1, m2 = models[i], models[j]
            s1, s2 = topk_sets[m1], topk_sets[m2]

            inter = len(s1 & s2)
            union = len(s1 | s2)
            jaccard = inter / union if union > 0 else 0.0

            results.append({
                "Ratio": topk_ratio,
                "Model1": m1,
                "Model2": m2,
                "Jaccard": jaccard
            })

            mat[idx[m1], idx[m2]] = jaccard
            mat[idx[m2], idx[m1]] = jaccard

    return mat, pd.DataFrame(results)

# -------------------------------------------
# 5. Compute matrices for 0.05 and 0.10
# -------------------------------------------
ratio1 = 0.05
ratio2 = 0.10

mat1, res1 = compute_jaccard_matrix(ratio1)
mat2, res2 = compute_jaccard_matrix(ratio2)

# 保存 CSV 结果（可选）
res1.to_csv("stability_results_0.05.csv", index=False)
res2.to_csv("stability_results_0.10.csv", index=False)
print("[INFO] Saved CSV: stability_results_0.05.csv, stability_results_0.10.csv")

# -------------------------------------------
# 6. Plot combined heatmap figure
# -------------------------------------------
# -------------------------------------------
# 6. Plot combined heatmap figure (bigger everything)
# -------------------------------------------
sns.set(font_scale=1.7)   # 全局字体放大

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(24, 12))  # 更大的画布

# 左图：0.05
h1 = sns.heatmap(
    mat1,
    ax=ax1,
    xticklabels=xyticks,
    yticklabels=xyticks,
    annot=True,
    cmap="viridis",
    vmin=0.0,
    vmax=1.0,
    fmt=".2f",
    cbar=False,
    annot_kws={"size": 16, "weight": "bold"}   # 数字更大
)
ax1.set_title("Top-5% (r = 0.05)", fontsize=28, fontweight="bold", pad=14)
ax1.set_xticklabels(ax1.get_xticklabels(), fontsize=28, fontweight="bold",
                    rotation=45, ha="right")
ax1.set_yticklabels(ax1.get_yticklabels(), fontsize=28, fontweight="bold", rotation=0)

# 右图：0.10
h2 = sns.heatmap(
    mat2,
    ax=ax2,
    xticklabels=xyticks,
    yticklabels=False,
    annot=True,
    cmap="viridis",
    vmin=0.0,
    vmax=1.0,
    fmt=".2f",
    cbar=False,
    annot_kws={"size": 16, "weight": "bold"}  # 数字更大
)
ax2.set_title("Top-10% (r = 0.10)", fontsize=28, fontweight="bold", pad=14)
ax2.set_xticklabels(ax2.get_xticklabels(), fontsize=28, fontweight="bold",
                    rotation=45, ha="right")

# 单独的 colorbar（大号 + 粗体）
cbar_ax = fig.add_axes([0.93, 0.15, 0.02, 0.70])
cbar = fig.colorbar(h2.collections[0], cax=cbar_ax)

cbar.set_label("Jaccard Similarity", fontsize=28, fontweight="bold")

# 刻度字号
cbar.ax.tick_params(labelsize=20)

# 刻度字体加粗（关键）
for tick in cbar.ax.get_yticklabels():
    tick.set_fontweight("bold")


# 总标题
fig.suptitle("FSS Weight Model Stability on Comd Benchmark",
             fontsize=32, fontweight="bold", y=0.98)

plt.tight_layout(rect=[0.03, 0.03, 0.90, 0.95])  # 留出 colorbar 空间
out_name = "stability_heatmap_0.05_0.10.pdf"
plt.savefig(out_name, dpi=300)
plt.close()
print(f"[INFO] Saved combined heatmap: {out_name}")

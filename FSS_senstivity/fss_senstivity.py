import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
import sys

"""
FSS Initialization and Stability Analysis Script
------------------------------------------------
Usage:
    python fss_stability_analysis.py stat_incremental_FSS_Score.csv 0.05

Arguments:
    input_csv   -- normalized + incremental FSS dataset
    topk_ratio  -- e.g., 0.05 (Top-5%)
Outputs:
    - stability_results.csv               (pairwise Jaccard)
    - stability_heatmap.png               (heatmap for paper)
"""

# ---------------------------
# 1. Load arguments
# ---------------------------
if len(sys.argv) < 3:
    print("Usage: python fss_stability_analysis.py <input_csv> <topk_ratio>")
    sys.exit(1)

input_csv = sys.argv[1]
topk_ratio = float(sys.argv[2])

print(f"[INFO] Input File: {input_csv}")
print(f"[INFO] Top-K Ratio: {topk_ratio}")

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
K = max(1, int(N * topk_ratio))
print(f"[INFO] Total instructions = {N}, Top-K = {K}")

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

# -------------------------------------------
# 4. Compute FSS under each model and collect Top-K sets
# -------------------------------------------
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

print("[INFO] FSS computed under all weight models.")

# -------------------------------------------
# 5. Pairwise Jaccard stability computation
# -------------------------------------------
models = list(weight_models.keys())
M = len(models)

results = []
mat = np.ones((M, M))  # diagonal = 1

idx = {m: i for i, m in enumerate(models)}

for i in range(M):
    for j in range(i + 1, M):
        m1, m2 = models[i], models[j]
        s1, s2 = topk_sets[m1], topk_sets[m2]

        inter = len(s1 & s2)
        union = len(s1 | s2)
        jaccard = inter / union if union > 0 else 0

        results.append({
            "Model1": m1,
            "Model2": m2,
            "Jaccard": jaccard
        })

        mat[idx[m1], idx[m2]] = jaccard
        mat[idx[m2], idx[m1]] = jaccard

# Save CSV
res_df = pd.DataFrame(results)
res_df.to_csv("stability_results.csv", index=False)
print("[INFO] Saved pairwise stability CSV: stability_results.csv")

# -------------------------------------------
# 6. Plot heatmap for the paper
# -------------------------------------------
# -------------------------------------------
# 6. Plot heatmap for the paper (larger fonts, bold)
# -------------------------------------------

plt.figure(figsize=(14, 12))

sns.set(font_scale=1.6)  # enlarge all seaborn fonts

ax = sns.heatmap(
    mat,
    xticklabels=models,
    yticklabels=models,
    annot=True,
    cmap="viridis",
    vmin=0.0,
    vmax=1.0,
    fmt=".2f",
    annot_kws={"size": 14, "weight": "bold"},   # annotated numbers bigger & bold
    cbar_kws={"label": "Jaccard Similarity"}
)

# Make x/y tick labels bold and larger
ax.set_xticklabels(ax.get_xticklabels(), fontsize=14, fontweight="bold", rotation=45, ha="right")
ax.set_yticklabels(ax.get_yticklabels(), fontsize=14, fontweight="bold", rotation=0)

# Title formatting
ax.set_title("FSS Weight Model Stability Analysis", fontsize=20, fontweight="bold", pad=20)

# Colorbar label font:
cbar = ax.collections[0].colorbar
cbar.ax.yaxis.label.set_size(16)
cbar.ax.yaxis.label.set_weight("bold")
cbar.ax.tick_params(labelsize=14)

plt.tight_layout()
plt.savefig("stability_heatmap.pdf", dpi=300)
plt.close()
print("[INFO] Saved heatmap: stability_heatmap.pdf (larger fonts)")

import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
import sys

"""
FSS Feature Correlation Analysis
--------------------------------
Usage:
    python fss_feature_correlation.py stat_incremental_FSS_Score.csv

Input:
    - CSV with columns:
      Opcode_Num_Norm, Bitwidth_Norm, Execution_Count_Norm, Avg_Latency_Norm

Outputs:
    - <base>_pearson_corr.csv
    - <base>_spearman_corr.csv
    - <base>_corr_heatmap.pdf  (Pearson & Spearman side by side, big fonts)
"""

# ---------------------------
# 1. Load arguments
# ---------------------------
if len(sys.argv) < 2:
    print("Usage: python fss_feature_correlation.py <input_csv>")
    sys.exit(1)

input_csv = sys.argv[1]
print(f"[INFO] Input file: {input_csv}")

if "." in input_csv:
    base = ".".join(input_csv.split(".")[:-1])
else:
    base = input_csv

# ---------------------------
# 2. Load CSV
# ---------------------------
df = pd.read_csv(input_csv)

feature_cols = [
    "Opcode_Num_Norm",
    "Bitwidth_Norm",
    "Execution_Count_Norm",
    "Avg_Latency_Norm",
]

missing = [c for c in feature_cols if c not in df.columns]
if missing:
    raise KeyError(f"Missing required columns: {missing}")

print(f"[INFO] Using feature columns: {feature_cols}")
print(f"[INFO] Number of instructions: {len(df)}")

# ---------------------------
# 3. Compute correlation matrices
# ---------------------------
pearson_corr = df[feature_cols].corr(method="pearson")
spearman_corr = df[feature_cols].corr(method="spearman")

pearson_out = base + "_pearson_corr.csv"
spearman_out = base + "_spearman_corr.csv"

pearson_corr.to_csv(pearson_out)
spearman_corr.to_csv(spearman_out)

print(f"[INFO] Saved Pearson correlation matrix to: {pearson_out}")
print(f"[INFO] Saved Spearman correlation matrix to: {spearman_out}")

# ---------------------------
# 4. Plot heatmaps (Pearson & Spearman in one figure)
# ---------------------------
sns.set(font_scale=1.7)  # global font scale

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(20, 10))

vmin, vmax = -1.0, 1.0  # correlation range

# 左：Pearson
h1 = sns.heatmap(
    pearson_corr,
    ax=ax1,
    vmin=vmin,
    vmax=vmax,
    annot=True,
    fmt=".2f",
    cmap="coolwarm",
    cbar=False,
    annot_kws={"size": 16, "weight": "bold"},
)

ax1.set_title("Pearson Correlation", fontsize=20, fontweight="bold", pad=14)
ax1.set_xticklabels(
    ax1.get_xticklabels(), fontsize=16, fontweight="bold", rotation=45, ha="right"
)
ax1.set_yticklabels(
    ax1.get_yticklabels(), fontsize=16, fontweight="bold", rotation=0
)

# 右：Spearman
h2 = sns.heatmap(
    spearman_corr,
    ax=ax2,
    vmin=vmin,
    vmax=vmax,
    annot=True,
    fmt=".2f",
    cmap="coolwarm",
    cbar=False,
    annot_kws={"size": 16, "weight": "bold"},
)

ax2.set_title("Spearman Correlation", fontsize=20, fontweight="bold", pad=14)
ax2.set_xticklabels(
    ax2.get_xticklabels(), fontsize=16, fontweight="bold", rotation=45, ha="right"
)
ax2.set_yticklabels(
    ax2.get_yticklabels(), fontsize=16, fontweight="bold", rotation=0
)

# 单独的 colorbar（共享两张图）
cbar_ax = fig.add_axes([0.93, 0.15, 0.02, 0.70])  # [left, bottom, width, height]
cbar = fig.colorbar(h2.collections[0], cax=cbar_ax)
cbar.set_label("Correlation", fontsize=20, fontweight="bold")
cbar.ax.tick_params(labelsize=16)
for tick in cbar.ax.get_yticklabels():
    tick.set_fontweight("bold")

# 总标题（可选）
fig.suptitle(
    "Correlation Between FSS Features", fontsize=22, fontweight="bold", y=0.98
)

plt.tight_layout(rect=[0.03, 0.03, 0.90, 0.95])

out_fig = base + "_corr_heatmap.pdf"
plt.savefig(out_fig, dpi=300)
plt.close()

print(f"[INFO] Saved correlation heatmap figure to: {out_fig}")
print("[INFO] Done.")


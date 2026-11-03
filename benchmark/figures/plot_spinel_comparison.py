"""Render supplied Hyperfine summary statistics as a candlestick-style chart.

The body is mean +/- sample standard deviation, not OHLC or quartiles.
The observed min/max are shown independently and are never clipped to the body.
"""
from pathlib import Path
import csv
import json
import os

os.environ.setdefault('MPLCONFIGDIR', '/private/tmp/wardite-matplotlib-config')
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager
from matplotlib.lines import Line2D
from matplotlib.patches import Patch, Rectangle

OUT = Path(__file__).resolve().parent
FONT = '/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc'
font_manager.fontManager.addfont(FONT)
FONT_NAME = font_manager.FontProperties(fname=FONT).get_name()
plt.rcParams.update({
    'font.family': FONT_NAME,
    'axes.unicode_minus': False,
    'font.size': 11,
    'svg.fonttype': 'path',
    'pdf.fonttype': 42,
})

ENGINES = [
    ('Efflorescence / Spinel', 'Efflorescence\nSpinel', '#2563EB'),
    ('iwasm (WAMR interpreter)', 'iwasm\nWAMR interpreter', '#0D9488'),
    ('Wasmtime (Pulley)', 'Wasmtime\nPulley', '#D68A0B'),
    ('Wasmtime', 'Wasmtime', '#7C3AED'),
]
# mean, standard deviation, minimum, maximum, runs; all times in milliseconds.
VALUES = {
    'inline_mix': [
        (13.4, 0.4, 13.0, 13.7, 5),
        (9.6, 1.7, 7.7, 12.1, 5),
        (8.6, 0.6, 7.9, 9.1, 5),
        (6.8, 0.3, 6.2, 7.1, 5),
    ],
    'call_mix': [
        (25.8, 0.6, 25.1, 26.7, 5),
        (6.0, 0.5, 5.5, 6.8, 5),
        (9.9, 0.3, 9.7, 10.3, 5),
        (7.2, 0.4, 6.5, 7.4, 5),
    ],
}

rows = []
for export, values in VALUES.items():
    for (engine, _, _), (mean, sd, minimum, maximum, runs) in zip(ENGINES, values):
        assert minimum <= mean <= maximum
        assert sd >= 0 and runs == 5
        rows.append(dict(export=export, engine=engine, mean_ms=mean, sd_ms=sd,
                         min_ms=minimum, max_ms=maximum, runs=runs))
(OUT / 'spinel_new_vm_summary.json').write_text(json.dumps({
    'source': 'User-provided Hyperfine summary',
    'body': 'mean +/- standard deviation',
    'whiskers': 'observed minimum and maximum',
    'data': rows,
}, ensure_ascii=False, indent=2) + '\n')
with (OUT / 'spinel_new_vm_summary.csv').open('w', newline='') as handle:
    writer = csv.DictWriter(handle, fieldnames=list(rows[0]), lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)

fig, axes = plt.subplots(1, 2, figsize=(15.6, 7.7), sharey=True)
fig.patch.set_facecolor('#F5F7FB')
fig.subplots_adjust(left=0.075, right=0.975, bottom=0.245, top=0.79, wspace=0.12)
fig.text(0.075, 0.944, 'Wasmランタイムの実行時間', fontsize=23, weight='bold', color='#17273D')
fig.text(0.075, 0.894, '各5回の計測  ·  小さいほど高速', fontsize=11.5, color='#5C6B80')

for ax, (export, values) in zip(axes, VALUES.items()):
    ax.set_facecolor('white')
    ax.set_title(export, loc='left', pad=18, fontsize=17, weight='bold', color='#17273D')
    ax.set_ylim(0, 30)
    ax.set_xlim(-0.55, 3.55)
    ax.set_yticks(range(0, 31, 5))
    ax.set_axisbelow(True)
    ax.grid(axis='y', color='#DFE5EE', linewidth=0.8)
    for spine in ('top', 'right'):
        ax.spines[spine].set_visible(False)
    for spine in ('left', 'bottom'):
        ax.spines[spine].set_color('#C6D0DD')
    ax.tick_params(axis='both', length=0, pad=10, labelcolor='#43536A')
    ax.set_xticks(range(4), [label for _, label, _ in ENGINES], fontsize=11)
    for x, ((_, _, color), (mean, sd, minimum, maximum, _)) in enumerate(zip(ENGINES, values)):
        # Draw the statistical interval first, then the observed range over it.
        ax.add_patch(Rectangle((x - 0.18, mean - sd), 0.36, 2 * sd,
                               facecolor=color, edgecolor=color, alpha=0.24,
                               linewidth=1.6, zorder=3))
        ax.vlines(x, minimum, maximum, color='#283950', linewidth=1.7, zorder=4)
        ax.hlines([minimum, maximum], x - 0.10, x + 0.10,
                  color='#283950', linewidth=1.7, zorder=5)
        ax.hlines(mean, x - 0.24, x + 0.24, color=color, linewidth=2.8, zorder=6)
        label_y = max(mean + sd, maximum) + 0.8
        ax.text(x, label_y, f'{mean:.1f} ± {sd:.1f} ms', ha='center', va='bottom',
                fontsize=12.0, weight='bold', color=color)
    for label, (_, _, color) in zip(ax.get_xticklabels(), ENGINES):
        label.set_color(color)
axes[0].set_ylabel('時間 (ms)', fontsize=12, labelpad=14, color='#43536A')

legend = [
    Patch(facecolor='#C9D7EC', edgecolor='#7187A6', label='胴体：平均 ± σ'),
    Line2D([0], [0], color='#2563EB', linewidth=2.8, label='中央線：平均'),
    Line2D([0], [0], color='#283950', marker='|', markersize=10, linewidth=1.5,
           label='ヒゲ：最小〜最大'),
]
fig.legend(handles=legend, loc='upper right', bbox_to_anchor=(0.983, 0.925),
           ncol=3, frameon=False, fontsize=10.5, handlelength=1.8, columnspacing=1.8)
fig.text(0.075, 0.12, '2つのパネルは同じ縦軸。ラベルは平均 ± 標準偏差（σ）。',
         fontsize=10.5, color='#43536A')
fig.text(0.075, 0.075, '平均 ± σ が実測の最小〜最大を超える箇所も、そのまま表示しています。',
         fontsize=10, color='#6E7C90')

for suffix in ('png', 'svg', 'pdf'):
    fig.savefig(OUT / f'spinel_new_vm_candlestick.{suffix}', dpi=180,
                facecolor=fig.get_facecolor(), metadata={'Creator': 'Wardite benchmark plot'})
svg = OUT / 'spinel_new_vm_candlestick.svg'
svg.write_text('\n'.join(line.rstrip() for line in svg.read_text().splitlines()) + '\n')
plt.close(fig)
print(OUT / 'spinel_new_vm_candlestick.png')

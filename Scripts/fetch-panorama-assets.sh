#!/usr/bin/env bash
#
# 全景验证素材获取脚本。
#
# 为什么要有它：三类全景要用的素材都是**大文件**（equirect 照片 2~4 MB、
# 360 视频 8~30 MB），全部入库会把仓库撑爆。所以：
#   - 素材本体落在 `.scratch/panorama-assets/`（已 gitignore，不进仓库）；
#   - **本脚本入库** —— 谁拿到仓库都能一条命令把同一批素材复原出来。
#
# 用法：
#   source ~/.zshrc && proxy_on          # 必须先开代理，直连不通
#   Scripts/fetch-panorama-assets.sh
#
# 依赖：curl、sips（macOS 自带）。代理从 http_proxy / https_proxy 环境变量取。
#
# ── 素材清单与许可 ──────────────────────────────────────────────────────────
#
# 分三类，对应 spec §3 的 A / B / C：
#
#   A 柱面宽幅（iPhone 全景形态，比例 3:1 ~ 5:1，**不是** equirect）
#   B equirect 照片（**比值必须正好 2:1**，这是 equirect 的强特征）
#   C equirect 360 视频
#
# | 类别 | 文件 | 尺寸 | 许可 | 来源 |
# |---|---|---|---|---|
# | B | equirect-nationalgalerie.jpg | 10000×5000 → 3840 | CC BY-SA 3.0 de | Wikimedia Commons |
# | B | equirect-duisburg-hochofen.jpg | 13876×6938 → 3840 | CC BY-SA 4.0 | Wikimedia Commons |
# | B | equirect-alma.jpg | 4096×2048 | 待核（Pannellum 样例） | pannellum.org |
# | A | cylindrical-eso-adaptive-optics.jpg | 13934×4638 → 3840 | **CC BY 4.0**（F. Kamphues/ESO） | Wikimedia Commons |
# | A | cylindrical-hindelang.jpg | 10000×2500 → 3840 | CC BY-SA 3.0（Jürgen Matern） | Wikimedia Commons |
# | C | 360-nasa-perseverance-13s.mp4 | 1752×876（正好 2:1） | **Public Domain**（17 USC §105, NASA） | HuggingFace 数据集 |
# | C | 360-nasa-stennis-62s.mp4 | 1920×960（正好 2:1） | **Public Domain**（同上） | HuggingFace 数据集 |
#
# ⚠️ 两条注意：
#   1. **B 类的 2:1 是硬要求**。比值不是 2 的图贴到 §4.2 的几何上会垂直拉伸 ——
#      而拉伸的观感"看起来只是有点怪"，不会报错。脚本里有一条硬校验，比值不对就退非零。
#   2. **A 类不能拿 equirect 顶替**。柱面展开贴球面会在垂直方向畸变（spec §3 结论 1），
#      所以 A 类素材必须是**真的柱面扫掠**（比值 3~5，且上下不是完整 180° 的极地内容）。
#
# 注意 `Special:FilePath?...&width=` 这个写法：它由 Commons 服务端缩放，
# 不依赖 `upload.wikimedia.org` 的哈希目录结构，比硬编码哈希路径稳。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.scratch/panorama-assets"

if [[ -z "${https_proxy:-}${HTTPS_PROXY:-}" ]]; then
    echo "✗ 没有设置 https_proxy —— 先 source ~/.zshrc && proxy_on" >&2
    exit 2
fi

COMMONS="https://commons.wikimedia.org/wiki/Special:FilePath"
HF="https://huggingface.co/datasets/TheMindExpansionNetwork/w0rldw3aver360-motion/resolve/main/clips"

mkdir -p "$OUT"

# 视频像素尺寸：有 ffprobe 就用（标准工具，不自造），没有返回非零。
# 本机若无 ffprobe，循环里会显式打"尺寸未探测"而不是猜一个数出来。
probe_video_dims() {
    command -v ffprobe >/dev/null 2>&1 || return 1
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height -of csv=p=0 "$1" 2>/dev/null |
        awk -F, 'NF==2 && $1+0>0 {print $1"x"$2; exit}'
}

# 文件名|URL|期望宽高比|说明
ITEMS=(
"equirect-nationalgalerie.jpg|$COMMONS/Alte%20Nationalgalerie%2C%20Berlin-Mitte%2C%20360%20Grad%20Panorama%2C%20160101%2C%20ako.jpg?width=3840|2.00|B equirect · CC BY-SA 3.0 de"
"equirect-duisburg-hochofen.jpg|$COMMONS/Landschaftspark-Duisburg-Nord%20Hochofen%20Panorama.jpg?width=3840|2.00|B equirect · CC BY-SA 4.0"
"equirect-alma.jpg|https://pannellum.org/images/alma.jpg|-|B equirect · 许可待核"
"cylindrical-eso-adaptive-optics.jpg|$COMMONS/Cylindrical%20panoramic%20Adaptive%20Optics%20%2816fkc18343-panorama-cylindrical-cc%29.jpg?width=3840|3.00|A 柱面 · CC BY 4.0 F. Kamphues/ESO"
"cylindrical-hindelang.jpg|$COMMONS/Bad%20Hindelang%20panorama%20view%20from%20south.jpg?width=3840|4.00|A 柱面 · CC BY-SA 3.0 Jürgen Matern"
"360-nasa-perseverance-13s.mp4|$HF/perseverance_first360_w01_13s.mp4|2.00|C 360 视频 · Public Domain (NASA)"
"360-nasa-stennis-62s.mp4|$HF/stennis_b2_w01_62s.mp4|2.00|C 360 视频 · Public Domain (NASA)"
)

fail=0
for entry in "${ITEMS[@]}"; do
    IFS='|' read -r name url want note <<< "$entry"
    dest="$OUT/$name"

    printf '%-40s' "$name"
    if [[ -s "$dest" ]]; then
        printf '已有，跳过  '
    else
        if ! curl -fsSL --max-time 300 --retry 2 -o "$dest.part" "$url"; then
            printf '✗ 下载失败\n'
            rm -f "$dest.part"
            fail=1
            continue
        fi
        mv "$dest.part" "$dest"
        printf 'ok        '
    fi

    if [[ "$name" == *.jpg ]]; then
        dims="$(sips -g pixelWidth -g pixelHeight "$dest" 2>/dev/null |
            awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{if(w&&h)print w"x"h}')"
    else
        dims="$(probe_video_dims "$dest" || true)"
    fi

    if [[ -z "$dims" ]]; then
        printf '%-12s 尺寸未探测（本机无 ffprobe）' "$(du -h "$dest" | cut -f1)"
    else
        ratio=$(awk -v d="$dims" 'BEGIN{split(d,a,"x"); printf "%.4f", a[1]/a[2]}')
        printf '%-12s r=%s' "$dims" "$ratio"
        if [[ "$want" != "-" ]]; then
            if awk -v r="$ratio" -v t="$want" 'BEGIN{exit (r>t-0.02 && r<t+0.02) ? 0 : 1}'; then
                printf '  ✓'
            else
                printf '  ✗ 期望 r≈%s' "$want"
                fail=1
            fi
        fi
    fi
    printf '  %s\n' "$note"
done

# 本地清单：素材不进仓库，但"这批是什么、什么许可"必须留痕
{
    echo "# 全景验证素材清单（本地，不入库）"
    echo
    echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo "目录：\`.scratch/panorama-assets/\`（已 gitignore）"
    echo
    echo "| 文件 | 尺寸 | 大小 | 说明 |"
    echo "|---|---|---|---|"
    for entry in "${ITEMS[@]}"; do
        IFS='|' read -r name _ _ note <<< "$entry"
        [[ -s "$OUT/$name" ]] || continue
        size="$(du -h "$OUT/$name" | cut -f1)"
        if [[ "$name" == *.jpg ]]; then
            dim="$(sips -g pixelWidth -g pixelHeight "$OUT/$name" 2>/dev/null |
                awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{if(w&&h)printf "%s×%s", w, h}')"
        else
            dim="$(probe_video_dims "$OUT/$name" 2>/dev/null |
                awk -F'x' 'NF==2{printf "%s×%s", $1, $2}' || true)"
        fi
        [[ -n "$dim" ]] || dim="（未探测）"
        echo "| \`$name\` | $dim | $size | $note |"
    done
    echo
    echo "再取一次：\`Scripts/fetch-panorama-assets.sh\`（已下的会跳过）"
} > "$OUT/manifest.md"

echo
echo "清单写入 $OUT/manifest.md"
if [[ "$fail" != 0 ]]; then
    echo "⚠️ 有项目失败或比例不符 —— 见上面的 ✗" >&2
    exit 1
fi
echo "全部就绪。"

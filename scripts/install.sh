#!/usr/bin/env bash
# =============================================================================
#  dsh-lossless-context — installer (macOS / Linux)
# =============================================================================
#  用法：
#    ./scripts/install.sh                      # profile=desktop, mode=balanced
#    ./scripts/install.sh memory-heavy         # 记忆敏感档
#    ./scripts/install.sh balanced web         # 指定 mode + profile
#    DSH_HOME=~/.dsh ./scripts/install.sh
# =============================================================================
set -euo pipefail

MODE="${1:-balanced}"
PROFILE="${2:-desktop}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"

case "$MODE" in
  balanced|memory-heavy) ;;
  *) echo "mode 必须是 balanced 或 memory-heavy"; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
PATCH_SRC="$REPO/patches/cordis.$MODE.yml"
TARGET="$DSH_HOME/profiles/$PROFILE/cordis.patch.yml"

echo
echo "dsh-lossless-context installer"
echo "  DSH_HOME : $DSH_HOME"
echo "  profile  : $PROFILE"
echo "  mode     : $MODE"
echo

[ -d "$DSH_HOME" ]     || { echo "找不到 DSH_HOME：$DSH_HOME"; exit 1; }
[ -f "$PATCH_SRC" ]    || { echo "找不到补丁模板：$PATCH_SRC"; exit 1; }
[ -f "$TARGET" ]       || { echo "找不到 profile 覆盖层：$TARGET"; exit 1; }

# 1) openseek-lcm
if [ -d "$DSH_HOME/profiles/$PROFILE/node_modules/openseek-lcm" ]; then
  echo "  [ok]   openseek-lcm 已安装"
else
  echo "  [warn] openseek-lcm 没装，请先执行（并关掉 DSH）："
  echo "           dsh plugin --profile $PROFILE add openseek-lcm"
fi

# 2) 冲突检测
IDS=$(grep -E '^- *id: *[A-Za-z0-9_-]+' "$PATCH_SRC" | sed -E 's/^- *id: *//' | tr -d ' \r')
CONFLICTS=""
while IFS= read -r id; do
  [ -z "$id" ] && continue
  if grep -qE "^- *id: *${id}[[:space:]]*$" "$TARGET"; then
    CONFLICTS="$CONFLICTS $id"
  fi
done <<< "$IDS"

if [ -n "${CONFLICTS// /}" ]; then
  echo
  echo "  [warn] 这些 id 已存在，未做修改："
  for c in $CONFLICTS; do echo "           - $c"; done
  echo
  echo "  请手动把 $PATCH_SRC 对应段落覆盖到 $TARGET 里已有的同名段落上。"
  exit 0
fi

# 3) 追加
STAMP=$(date +%Y%m%d-%H%M%S)
cp "$TARGET" "$TARGET.bak-$STAMP"

{
  printf '\n# ─────────────────────────────────────────────────────────────\n'
  printf '#  dsh-lossless-context（%s）\n' "$MODE"
  printf '#  安装于 %s\n' "$STAMP"
  printf '#  卸载：删掉本段以下的所有内容，并重启 DSH\n'
  printf '# ─────────────────────────────────────────────────────────────\n\n'
  cat "$PATCH_SRC"
} >> "$TARGET"

echo "  [ok]   已追加：$(echo $IDS | tr '\n' ' ')"
echo "  [ok]   原文件已备份：$TARGET.bak-$STAMP"
echo
echo "下一步："
echo "  1. 完全退出并重新打开 DeepSeek Harness"
echo "  2. 在任意会话输入  /lcm status"
echo "  3. 验证：node tests/acceptance.mjs"
echo

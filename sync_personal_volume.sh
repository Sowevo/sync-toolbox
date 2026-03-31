#!/usr/bin/env bash
set -euo pipefail

export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

# 统一 gum 标题颜色
export GUM_CHOOSE_HEADER_FOREGROUND="${GUM_CHOOSE_HEADER_FOREGROUND:-4}"
export GUM_INPUT_HEADER_FOREGROUND="${GUM_INPUT_HEADER_FOREGROUND:-4}"

if [ -n "${ZSH_VERSION-}" ]; then
  emulate -L sh
  setopt SH_WORD_SPLIT
fi

trap 'echo "已取消，脚本退出。"; exit 130' INT TERM

echo "=== personal_volume 同步脚本（mac）==="

ensure_gum() {
  if command -v gum >/dev/null 2>&1; then
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    echo "未检测到 gum。"
    echo "⚠️ 危险操作检测！"
    echo "操作类型：安装依赖（brew install gum）"
    echo "影响范围：系统包管理"
    echo "风险评估：会安装 gum 及其依赖"
    echo "(哼，这种危险的操作需要本小姐特别确认！笨蛋快说\"yes\"！)"
    printf "%s" "确认输入（请输入 yes 继续）: "
    read -r CONFIRM_INSTALL
    if [ "$CONFIRM_INSTALL" = "yes" ]; then
      brew install gum
      return $?
    fi
  fi
  return 1
}

GUM_READY=0
if ensure_gum; then
  GUM_READY=1
fi

gum_choose() {
  # $1 prompt, $2.. options
  prompt="$1"
  shift
  if [ "$GUM_READY" -eq 1 ]; then
    choice="$(gum choose --header="$prompt" "$@" || true)"
    if [ -z "$choice" ]; then
      printf "%s" "__CANCEL__"
      return 0
    fi
    printf "%s" "$choice"
  else
    echo "$prompt"
    idx=1
    for opt in "$@"; do
      echo "  ${idx}) ${opt}"
      idx=$((idx + 1))
    done
    printf "%s" "请输入编号（回车取消）: "
    read -r pick
    if [ -z "$pick" ]; then
      printf "%s" "__CANCEL__"
      return 0
    fi
    case "$pick" in
      *[!0-9]* )
        printf "%s" "__CANCEL__"
        return 0
        ;;
      * )
        if [ "$pick" -ge 1 ] && [ "$pick" -le "$((idx - 1))" ]; then
          i=1
          for opt in "$@"; do
            if [ "$i" -eq "$pick" ]; then
              printf "%s" "$opt"
              return 0
            fi
            i=$((i + 1))
          done
        fi
        ;;
    esac
    printf "%s" "__CANCEL__"
  fi
}

gum_input() {
  # $1 prompt, $2 default
  prompt="$1"
  default="$2"
  if [ "$GUM_READY" -eq 1 ]; then
    if [ -n "$default" ]; then
      prompt="${prompt}（默认值为 ${default}）"
    fi
    if [ -n "$default" ]; then
      val="$(gum input --header="$prompt" --prompt="> " --value="$default")"
      rc=$?
    else
      val="$(gum input --header="$prompt" --prompt="> ")"
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      printf "%s" "__CANCEL__"
      return 0
    fi
    if [ -z "${val:-}" ]; then
      printf "%s" "$default"
      return 0
    fi
    printf "%s" "$val"
  else
    if [ -n "$default" ]; then
      printf "%s" "$prompt (默认 $default): "
    else
      printf "%s" "$prompt: "
    fi
    read -r val
    if [ -z "$val" ]; then
      printf "%s" "$default"
    else
      printf "%s" "$val"
    fi
  fi
}

check_cancel() {
  if [ "$1" = "__CANCEL__" ]; then
    echo "已取消，脚本退出。"
    exit 130
  fi
}

SRC_MODE_CHOICE="$(gum_choose "选择源类型" \
  "本地路径（已挂载 SMB 或在 NAS 本机执行）" \
  "远程 SSH 源（本机执行，从 NAS 拉取）")"
check_cancel "$SRC_MODE_CHOICE"

if [ "$SRC_MODE_CHOICE" = "远程 SSH 源（本机执行，从 NAS 拉取）" ]; then
  SRC_MODE="2"
else
  SRC_MODE="1"
fi
echo "源类型: ${SRC_MODE_CHOICE}"

SRC_ROOT=""
if [ "$SRC_MODE" = "2" ]; then
  SRC_SSH="$(gum_input "请输入远程地址" "sowevo@10.0.0.3")"
  check_cancel "$SRC_SSH"
  if [ -z "$SRC_SSH" ]; then
    echo "远程地址不能为空，退出。"
    exit 1
  fi
  echo "远程地址: ${SRC_SSH}"
  SRC_PATH="$(gum_input "请输入远程源路径" "/vol2/1000/personal_volume")"
  check_cancel "$SRC_PATH"
  if [ -z "$SRC_PATH" ]; then
    echo "远程源路径不能为空，退出。"
    exit 1
  fi
  echo "远程源路径: ${SRC_PATH}"
  SRC_ROOT="${SRC_SSH}:${SRC_PATH}"
else
  SRC_ROOT="$(gum_input "请输入源路径" "/vol2/1000/personal_volume")"
  check_cancel "$SRC_ROOT"
  echo "源路径: ${SRC_ROOT}"
fi

detect_usb_candidates() {
  local vol info_file removable external

  if command -v diskutil >/dev/null 2>&1; then
    for vol in /Volumes/*; do
      [ -d "$vol" ] || continue
      info_file="$(mktemp)"
      if diskutil info -plist "$vol" >"$info_file" 2>/dev/null; then
        removable="$(/usr/libexec/PlistBuddy -c "Print :Removable Media" "$info_file" 2>/dev/null || echo "false")"
        external="$(/usr/libexec/PlistBuddy -c "Print :Device Location" "$info_file" 2>/dev/null || echo "")"
        rem_or_ext="$(/usr/libexec/PlistBuddy -c "Print :RemovableMediaOrExternalDevice" "$info_file" 2>/dev/null || echo "false")"
        internal="$(/usr/libexec/PlistBuddy -c "Print :Internal" "$info_file" 2>/dev/null || echo "true")"
        if [ "$removable" = "true" ] || [ "$external" = "External" ] || [ "$rem_or_ext" = "true" ] || [ "$internal" = "false" ]; then
          printf "%s\n" "$vol"
        fi
      fi
      rm -f "$info_file"
    done
  fi
}

USB_CANDIDATES_FILE="$(mktemp)"
detect_usb_candidates >"$USB_CANDIDATES_FILE"
USB_CANDIDATES_COUNT="$(wc -l <"$USB_CANDIDATES_FILE" | tr -d ' ')"

if [ "$USB_CANDIDATES_COUNT" -eq 0 ]; then
  USB_CANDIDATES_COUNT=0
fi

echo "自动识别到的外置卷数量：$USB_CANDIDATES_COUNT"
if [ "$USB_CANDIDATES_COUNT" -eq 0 ]; then
  echo "未识别到外置卷，将进入手动输入。"
fi

if [ "$USB_CANDIDATES_COUNT" -gt 0 ]; then
  set --
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    set -- "$@" "$line"
  done <"$USB_CANDIDATES_FILE"
  USB_PICK_CHOICE="$(gum_choose "选择目标U盘卷" "$@")"
  check_cancel "$USB_PICK_CHOICE"
  if [ -n "$USB_PICK_CHOICE" ]; then
    USB_DEFAULT="${USB_PICK_CHOICE}/personal_volume_backup"
    DST_ROOT="$(gum_input "请输入目标U盘路径" "$USB_DEFAULT")"
    check_cancel "$DST_ROOT"
    echo "目标卷: ${USB_PICK_CHOICE}"
  else
    DST_ROOT="$(gum_input "请输入目标U盘路径" "")"
    check_cancel "$DST_ROOT"
  fi
else
  DST_ROOT="$(gum_input "请输入目标U盘路径" "")"
  check_cancel "$DST_ROOT"
fi
rm -f "$USB_CANDIDATES_FILE"

if [ -z "$DST_ROOT" ]; then
  echo "目标路径不能为空，退出。"
  exit 1
fi
echo "目标路径: ${DST_ROOT}"

DIRS_INPUT="$(gum_input "输入目录名，用空格分隔（直接回车用默认）" "photos videos docs software")"
check_cancel "$DIRS_INPUT"
if [ -z "$DIRS_INPUT" ]; then
  DIRS_ARR=(photos videos docs software)
else
  DIRS_ARR=($DIRS_INPUT)
fi
echo "同步目录: ${DIRS_ARR[*]}"

MIRROR_CHOICE="$(gum_choose "是否镜像同步（会删除目标多余文件）" \
  "增量同步（安全，不删除目标多余文件）" \
  "镜像同步（危险，会删除目标多余文件）")"
check_cancel "$MIRROR_CHOICE"
echo "同步模式: ${MIRROR_CHOICE}"

MIRROR_CONFIRM="no"
if [ "$MIRROR_CHOICE" = "镜像同步（危险，会删除目标多余文件）" ]; then
  MIRROR_CONFIRM="yes"
fi
MIRROR=0
if [ "$MIRROR_CONFIRM" = "yes" ]; then
  echo "⚠️ 危险操作检测！"
  echo "操作类型：镜像同步（删除目标多余文件）"
  echo "影响范围：$DST_ROOT 下所选目录"
  echo "风险评估：可能删除目标中不在源中的文件"
  echo "(哼，这种危险的操作需要本小姐特别确认！笨蛋快说\"yes\"！)"
  printf "%s" "确认输入（请输入 yes 继续）: "
  read -r DANGER_OK
  if [ "$DANGER_OK" != "yes" ]; then
    echo "未确认危险操作，切换为增量同步。"
    MIRROR=0
  else
    MIRROR=1
  fi
fi

RUN_CHOICE="$(gum_choose "执行模式" \
  "预演（dry-run，不实际写入）" \
  "直接执行（会写入目标）")"
check_cancel "$RUN_CHOICE"
echo "执行模式: ${RUN_CHOICE}"

DRY_RUN_CONFIRM="no"
if [ "$RUN_CHOICE" = "直接执行（会写入目标）" ]; then
  DRY_RUN_CONFIRM="yes"
fi
DRY_RUN=1
if [ "$DRY_RUN_CONFIRM" = "yes" ]; then
  DRY_RUN=0
fi

RSYNC_OPTS=(
  "-a"
  "-v"
  "--human-readable"
  "--progress"
  "--8-bit-output"
  "--exclude=._*"
  "--exclude=.DS_Store"
)

if rsync --version 2>/dev/null | grep -qi "iconv"; then
  RSYNC_OPTS+=("--iconv=UTF-8,UTF-8")
fi

if [ "$MIRROR" -eq 1 ]; then
  RSYNC_OPTS+=("--delete")
fi

if [ "$DRY_RUN" -eq 1 ]; then
  RSYNC_OPTS+=("--dry-run")
fi

echo "源路径: $SRC_ROOT"
echo "目标路径: $DST_ROOT"
echo "目录: ${DIRS_ARR[*]}"
echo "镜像删除: $([ "$MIRROR" -eq 1 ] && echo 是 || echo 否)"
echo "预演: $([ "$DRY_RUN" -eq 1 ] && echo 是 || echo 否)"
echo "开始同步..."

for d in "${DIRS_ARR[@]}"; do
  if [ "$SRC_MODE" = "2" ]; then
    src="${SRC_ROOT}/${d}/"
  else
    src="${SRC_ROOT}/${d}/"
  fi
  dst="$DST_ROOT/$d/"
  echo "Sync: $src -> $dst"
  rsync "${RSYNC_OPTS[@]}" "$src" "$dst"
done

echo "Done."

#!/usr/bin/env bash
#
# bfid.sh — BFId 復刻：擷取端 建置 / 監聽 / 驗證 一把抓
# =============================================================
#
# 這支腳本把 2026-09-28 那次實機除錯的所有結論固化下來，包含幾個
# 不照做就一定會卡住的地方：
#
#   1. Intel 網卡是 self-managed 法規域，`iw reg set TW` 對它無效。
#   2. mac80211 對 real-chanctx 驅動（iwlwifi）有個 bug：monitor 介面
#      若沒有自己的 channel context，封包會被靜默丟棄——抓到 0 個。
#      解法是讓 wlp1s0 先關聯上 AP，monitor 介面再跟著它的頻道走。
#      所以 shared 模式「不」對 mon0 下 set freq。
#   3. monitor 介面要帶 `otherbss control` 旗標，否則只收得到廣播幀
#      與寄給自己的幀，抓不到其他客戶端的單播 CBFR。
#   4. tcpdump 在 Ubuntu 會降權到 tcpdump 使用者，要用 -Z 指定擁有者，
#      並且用 `timeout -s INT` 讓它乾淨收尾，否則 pcap 會被截斷。
#   5. 6 GHz 的 80/160 MHz 要填「所屬區塊」的中心頻率，不是通道頻率。
#   6. iwlwifi 在 managed+monitor 並存時只遞送極少數幀（實測 20 秒 24 個），
#      當不了 recording node。論文架構是另一張「不在網路裡」的錄製卡，
#      也就是 recorder 模式。
#   7. main.py 的封包數參數必須 ≤「該 MAC」的 CBFR 數，否則 StopIteration。
#      所以本腳本計數時一律加上 wlan.addr==TARGET_MAC，與 main.py 同一個過濾條件。
#
# 兩種模式（設定 MODE）：
#   shared    AX210 一張卡：wlp1s0 關聯 AP 撐住 channel context，mon0 跟著走。
#             只適合除錯，iwlwifi 的遞送限制會讓 CBFR 很少。
#   recorder  獨立錄製卡（MT7921AU / MT7925 USB）：不關聯任何 AP，
#             monitor 介面直接鎖 CHAN_FREQ / CHAN_WIDTH / CHAN_CENTER。
#             這才是論文的 recording node。
#
# 用法：
#   ./bfid.sh doctor              環境健檢，不改動任何東西
#   ./bfid.sh setup               裝套件、建 conda 環境、clone Wi-BFI
#   ./bfid.sh up                  依 MODE 建立 monitor 介面
#   ./bfid.sh verify [秒數]       關卡驗證：到底抓不抓得到 CBFR
#   ./bfid.sh capture <標籤> [秒數]  正式錄製
#   ./bfid.sh status              看目前狀態
#   ./bfid.sh down                拆掉 monitor 介面
#
# 設定：改下面的變數，或放一份 ~/.bfid.conf 覆蓋（同樣語法）。
# 也可以臨時用環境變數：MODE=recorder REC_IF=wlx00c0cafe1234 ./bfid.sh up
#
set -uo pipefail

# ------------------------------------------------------------------
# 設定
# ------------------------------------------------------------------
MODE="${MODE:-shared}"                # shared / recorder

WIFI_IF="${WIFI_IF:-wlp1s0}"          # shared：AX210 的 managed 介面
REC_IF="${REC_IF:-}"                  # recorder：USB 錄製卡的介面（例 wlx00c0cafe1234）
MON_IF="${MON_IF:-mon0}"              # 要建立的 monitor 介面
PHY="${PHY:-}"                        # 留空則由介面自動偵測

SSID="${SSID:-3290-6g}"               # 6 GHz 專用 SSID（shared 模式才會連）
WIFI_PSK="${WIFI_PSK:-}"              # 留空則從 ~/.bfid.conf 讀，或互動輸入
CON_NAME="${CON_NAME:-bfid-6g}"       # NetworkManager 連線名稱

TARGET_MAC="${TARGET_MAC:-94:89:78:79:35:b9}"   # beamformee（iPhone）
AP_MAC="${AP_MAC:-ca:4f:86:66:2f:a0}"

STANDARD="${STANDARD:-AX}"            # AX / AC
ANT_CFG="${ANT_CFG:-4x2}"             # Wi-BFI 天線組態
CHAN_FREQ="${CHAN_FREQ:-6135}"        # ch37
CHAN_WIDTH="${CHAN_WIDTH:-160}"
CHAN_CENTER="${CHAN_CENTER:-6185}"    # 160 MHz 區塊中心（ch47）

# 台灣 6 GHz 開放範圍（NCC，2023-08-25 起，與歐盟相同）
TW_6G_LO=5945
TW_6G_HI=6425

CAPTURE_DIR="${CAPTURE_DIR:-$HOME/bfid/captures}"
WIBFI_DIR="${WIBFI_DIR:-$HOME/Wi-BFI}"
CONDA_ENV="${CONDA_ENV:-wi-bfi}"

[ -f "$HOME/.bfid.conf" ] && . "$HOME/.bfid.conf"

# ------------------------------------------------------------------
# 輸出
# ------------------------------------------------------------------
if [ -t 1 ]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; D=$'\033[2m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; B=""; D=""; N=""
fi

ok()   { printf '%s  OK  %s %s\n' "$G" "$N" "$*"; }
bad()  { printf '%s FAIL %s %s\n' "$R" "$N" "$*"; }
warn() { printf '%s WARN %s %s\n' "$Y" "$N" "$*"; }
info() { printf '%s      %s%s\n' "$D" "$*" "$N"; }
head_() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
die()  { bad "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# 取得 sudo（提早問密碼，免得卡在半途）
need_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        warn "你是 root。建議用一般使用者執行，腳本會在需要時自行 sudo。"
        return 0
    fi
    sudo -v || die "需要 sudo 權限"
}

# ------------------------------------------------------------------
# 共用小工具
# ------------------------------------------------------------------
check_mode() {
    case "$MODE" in
        shared|recorder) ;;
        *) die "MODE 只能是 shared 或 recorder（目前是 '$MODE'）" ;;
    esac
}

# 目前模式下，實體網卡是哪個介面
base_if() {
    if [ "$MODE" = "recorder" ]; then echo "$REC_IF"; else echo "$WIFI_IF"; fi
}

# 介面 → phy 名稱
phy_of() {
    iw dev "$1" info 2>/dev/null | awk '/wiphy/ {print "phy"$2}'
}

resolve_phy() {
    if [ -n "$PHY" ]; then echo "$PHY"; return; fi
    phy_of "$(base_if)"
}

driver_of() {
    local d="/sys/class/net/$1/device/driver"
    [ -e "$d" ] && basename "$(readlink -f "$d")"
}

cbfr_filter() {
    if [ "$STANDARD" = "AX" ]; then
        echo 'wlan.he.mimo.feedback_type==SU'
    else
        echo 'wlan.vht.mimo_control.feedbacktype==SU'
    fi
}

# count_cbfr <pcap> [mac] — 給 mac 時與 main.py 的過濾條件完全一致
count_cbfr() {
    local pcap="$1" mac="${2:-}" f
    f=$(cbfr_filter)
    [ -n "$mac" ] && f="$f && wlan.addr==$mac"
    tshark -r "$pcap" -Y "$f" 2>/dev/null | wc -l | tr -d ' '
}

# 檢查設定的頻道是否落在台灣 6 GHz 範圍內，且主頻道在區塊內
check_tw_range() {
    [ "$CHAN_FREQ" -lt 5900 ] && { info "非 6 GHz（$CHAN_FREQ MHz），略過台灣 6 GHz 範圍檢查"; return 0; }
    local lo hi
    if [ "$CHAN_WIDTH" = "20" ]; then
        lo=$((CHAN_FREQ - 10)); hi=$((CHAN_FREQ + 10))
    else
        lo=$((CHAN_CENTER - CHAN_WIDTH / 2)); hi=$((CHAN_CENTER + CHAN_WIDTH / 2))
        if [ "$CHAN_FREQ" -le "$lo" ] || [ "$CHAN_FREQ" -ge "$hi" ]; then
            bad "主頻道 $CHAN_FREQ MHz 不在區塊 ${lo}–${hi} MHz 內 — CHAN_CENTER 填錯了"
            return 1
        fi
        # 6 GHz 區塊從 5945 MHz 起算，邊界必須對齊頻寬
        if [ $(( (lo - 5945) % CHAN_WIDTH )) -ne 0 ]; then
            bad "${lo}–${hi} MHz 不是合法的 ${CHAN_WIDTH} MHz 區塊（CHAN_CENTER=$CHAN_CENTER 填錯）"
            return 1
        fi
    fi
    if [ "$lo" -lt "$TW_6G_LO" ] || [ "$hi" -gt "$TW_6G_HI" ]; then
        bad "佔用 ${lo}–${hi} MHz，超出台灣 ${TW_6G_LO}–${TW_6G_HI} MHz"
        return 1
    fi
    ok "佔用 ${lo}–${hi} MHz，在台灣 ${TW_6G_LO}–${TW_6G_HI} MHz 內"
}

# 建立帶 otherbss/control 旗標的 monitor 介面
make_monitor() {
    local phy="$1"
    sudo ip link set "$MON_IF" down 2>/dev/null
    sudo iw dev "$MON_IF" del 2>/dev/null
    # otherbss = 關閉 BSSID 過濾；control = 收控制幀
    if ! sudo iw phy "$phy" interface add "$MON_IF" type monitor flags otherbss control 2>/dev/null; then
        warn "帶旗標建立失敗，改用無旗標建立後再設定"
        sudo iw phy "$phy" interface add "$MON_IF" type monitor || die "建立 monitor 介面失敗"
        sudo ip link set "$MON_IF" down
        sudo iw dev "$MON_IF" set monitor otherbss control || warn "設定旗標失敗"
    fi
    sudo ip link set "$MON_IF" up || die "無法啟用 $MON_IF"
    sudo nmcli device set "$MON_IF" managed no 2>/dev/null   # 失敗是正常的，NM 不管 monitor
    ok "$MON_IF 已建立並啟用（$phy）"
}

# ==================================================================
# doctor — 只讀，不改動
# ==================================================================
cmd_doctor() {
    local fails=0 bif phy
    check_mode
    bif=$(base_if)

    head_ "系統"
    info "核心 $(uname -r)"
    if [ -r /etc/os-release ]; then
        info "$(. /etc/os-release && echo "$PRETTY_NAME")"
    fi
    info "模式 MODE=$MODE"

    head_ "必要指令"
    for c in iw ip tcpdump tshark nmcli capinfos; do
        if need_cmd "$c"; then ok "$c"; else bad "$c 未安裝"; fails=$((fails+1)); fi
    done
    if need_cmd conda; then ok "conda"; else warn "conda 未安裝（跑 setup 會處理）"; fi

    head_ "網卡"
    info "目前所有無線介面："
    iw dev 2>/dev/null | awk '/phy#/ {p=$1} /Interface/ {print "  " p " " $2}' \
        | while read -r l; do info "$l"; done
    if [ -z "$bif" ]; then
        bad "MODE=recorder 但沒設 REC_IF — 從上面清單挑 USB 錄製卡的介面名"
        fails=$((fails+1))
    elif ip link show "$bif" >/dev/null 2>&1; then
        ok "$bif 存在，驅動 $(driver_of "$bif" || echo 未知)"
        if [ "$MODE" = "recorder" ] && [ "$(driver_of "$bif")" = "iwlwifi" ]; then
            warn "recorder 模式選到 iwlwifi 網卡 — 這正是要避開的，應該是 mt7921u / mt7925u"
        fi
    else
        bad "$bif 不存在 — 用 'iw dev' 確認實際名稱，再改設定"
        fails=$((fails+1))
    fi
    if lspci 2>/dev/null | grep -qi 'AX210\|Wi-Fi 6E'; then
        ok "偵測到 AX210 等級網卡"
    fi
    if lsusb 2>/dev/null | grep -qi 'MediaTek'; then
        ok "偵測到 MediaTek USB 網卡"
    elif [ "$MODE" = "recorder" ]; then
        warn "lsusb 沒看到 MediaTek 裝置"
    fi

    head_ "6 GHz 支援"
    phy=$(resolve_phy)
    if [ -z "$phy" ]; then
        bad "找不到 $bif 的 phy"; fails=$((fails+1))
    else
        info "檢查 $phy"
        local n6
        n6=$(iw phy "$phy" info 2>/dev/null | grep -cE '\* (59[4-9][0-9]|6[0-4][0-9][0-9])(\.0)? MHz')
        if [ "$n6" -gt 0 ]; then
            ok "看得到 $n6 個 6 GHz 頻率"
            if iw phy "$phy" info 2>/dev/null | grep -qE "\* ${CHAN_FREQ}(\.0)? MHz"; then
                ok "目標頻率 ${CHAN_FREQ} MHz 可用"
            else
                bad "看不到 ${CHAN_FREQ} MHz"; fails=$((fails+1))
            fi
        else
            bad "看不到任何 6 GHz 頻率 — 更新 linux-firmware 與核心"
            fails=$((fails+1))
        fi
    fi

    head_ "法規域與頻道"
    iw reg get 2>/dev/null | sed -n '1,3p' | while read -r l; do info "$l"; done
    if iw reg get 2>/dev/null | grep -q 'self-managed'; then
        warn "有網卡是 self-managed，'iw reg set' 對它無效（Intel 正常現象）"
    fi
    check_tw_range || fails=$((fails+1))

    head_ "Wi-BFI"
    if [ -f "$WIBFI_DIR/main.py" ]; then ok "$WIBFI_DIR"; else warn "找不到 $WIBFI_DIR（跑 setup 會 clone）"; fi

    head_ "結論"
    if [ "$fails" -eq 0 ]; then
        ok "健檢通過，可以往下跑 setup / up"
    else
        bad "有 $fails 項必須先解決"
        return 1
    fi
}

# ==================================================================
# setup — 裝環境
# ==================================================================
cmd_setup() {
    need_sudo

    head_ "系統套件"
    sudo apt-get update -qq
    sudo apt-get install -y tshark wireshark-common aircrack-ng iw iperf3 \
                            wireless-regdb git curl wget usbutils \
        || die "apt 安裝失敗（Ubuntu 非 LTS 版 EOL 後套件庫會搬到 old-releases）"
    ok "套件安裝完成"

    head_ "Miniconda"
    if need_cmd conda; then
        ok "conda 已存在：$(command -v conda)"
    elif [ -x "$HOME/miniconda3/bin/conda" ]; then
        ok "找到 $HOME/miniconda3，初始化中"
        "$HOME/miniconda3/bin/conda" init bash >/dev/null
        warn "請重開 shell 或 source ~/.bashrc 後重跑 setup"
        return 0
    else
        info "下載 Miniconda"
        local sh=/tmp/miniconda.sh
        wget -q -O "$sh" https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh \
            || die "下載失敗"
        bash "$sh" -b -p "$HOME/miniconda3" || die "安裝失敗"
        "$HOME/miniconda3/bin/conda" init bash >/dev/null
        "$HOME/miniconda3/bin/conda" config --set auto_activate_base false
        rm -f "$sh"
        ok "Miniconda 裝好了"
        warn "請重開 shell 或 source ~/.bashrc 後重跑 setup"
        return 0
    fi

    head_ "conda 環境 $CONDA_ENV"
    # shellcheck disable=SC1091
    . "$(conda info --base)/etc/profile.d/conda.sh"
    if conda env list | awk '{print $1}' | grep -qx "$CONDA_ENV"; then
        ok "環境已存在"
    else
        conda create -n "$CONDA_ENV" python=3.10 -y || die "建立環境失敗"
        ok "環境建立完成"
    fi
    conda activate "$CONDA_ENV" || die "無法啟動環境"
    # Wi-BFI 只用到基本 numpy 函式，numpy 2.x 相容，不需降版
    pip install -q pyshark==0.6 numpy matplotlib lxml || die "pip 安裝失敗"
    ok "Python 套件安裝完成"

    head_ "Wi-BFI"
    if [ -d "$WIBFI_DIR/.git" ]; then
        ok "已存在 $WIBFI_DIR"
    else
        git clone -q https://github.com/kfoysalhaque/Wi-BFI.git "$WIBFI_DIR" || die "clone 失敗"
        ok "clone 完成"
    fi

    mkdir -p "$CAPTURE_DIR"
    head_ "完成"
    info "下一步：./bfid.sh up"
}

# ==================================================================
# up — 依模式建立 monitor
# ==================================================================
cmd_up() {
    check_mode
    need_sudo
    if [ "$MODE" = "recorder" ]; then cmd_up_recorder; else cmd_up_shared; fi
}

# shared：AX210 關聯 AP + monitor 跟著它的頻道走
cmd_up_shared() {
    warn "shared 模式：iwlwifi 並存時遞送的幀很少，只適合除錯。正式錄製請用 MODE=recorder"

    head_ "步驟 1/3：讓 $WIFI_IF 回到 managed"
    sudo ip link set "$WIFI_IF" down 2>/dev/null
    sudo iw dev "$WIFI_IF" set type managed 2>/dev/null
    sudo ip link set "$WIFI_IF" up
    sudo nmcli device set "$WIFI_IF" managed yes 2>/dev/null
    nmcli radio wifi on 2>/dev/null
    sleep 2
    ok "已還原為 managed"

    head_ "步驟 2/3：關聯到 $SSID"
    info "monitor 介面需要另一個介面撐住 channel context，這步不能省"
    if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$CON_NAME"; then
        local cur_ssid
        cur_ssid=$(nmcli -g 802-11-wireless.ssid connection show "$CON_NAME" 2>/dev/null)
        if [ "$cur_ssid" != "$SSID" ]; then
            warn "既有連線 $CON_NAME 綁的是 '$cur_ssid'，更新為 '$SSID'"
            sudo nmcli connection modify "$CON_NAME" 802-11-wireless.ssid "$SSID" \
                || die "更新 SSID 失敗"
        else
            info "使用既有連線設定 $CON_NAME"
        fi
    else
        local psk="$WIFI_PSK"
        if [ -z "$psk" ]; then
            read -r -s -p "  $SSID 的密碼：" psk; echo
        fi
        # 6 GHz 強制 WPA3-SAE，明確指定 key-mgmt 比較保險
        sudo nmcli connection add type wifi ifname "$WIFI_IF" con-name "$CON_NAME" \
             ssid "$SSID" wifi-sec.key-mgmt sae wifi-sec.psk "$psk" >/dev/null \
            || die "建立連線設定失敗"
        ok "已建立連線設定 $CON_NAME"
    fi

    sudo nmcli connection up "$CON_NAME" >/dev/null || die "連線失敗 — 確認 AP 開著、SSID 是 $SSID 且密碼正確"
    sleep 2

    local freq
    freq=$(iw dev "$WIFI_IF" link 2>/dev/null | awk '/freq:/ {print $2}')
    if [ -z "$freq" ]; then
        die "沒有連上 — iw dev $WIFI_IF link 沒有頻率資訊"
    fi
    ok "已連線，freq $freq MHz"
    if [ "${freq%%.*}" != "$CHAN_FREQ" ]; then
        warn "連到 $freq MHz，不是預期的 $CHAN_FREQ MHz"
        info "檢查 AP 是否開了 band steering，或 SSID 同時存在於多個頻段"
    fi
    iw dev "$WIFI_IF" link | grep -E 'bitrate|signal' | while read -r l; do info "$l"; done

    head_ "步驟 3/3：建立 monitor 介面 $MON_IF"
    local phy
    phy=$(resolve_phy); [ -z "$phy" ] && die "找不到 $WIFI_IF 的 phy"
    make_monitor "$phy"
    info "刻意不對 $MON_IF 下 set freq — 它跟著 $WIFI_IF 的頻道走"

    head_ "完成"
    info "下一步：./bfid.sh verify"
}

# recorder：獨立錄製卡，不關聯，直接鎖頻道
cmd_up_recorder() {
    [ -z "$REC_IF" ] && die "MODE=recorder 需要設定 REC_IF（USB 錄製卡的介面名，用 'iw dev' 查）"
    [ "$REC_IF" = "$WIFI_IF" ] && die "REC_IF 與 WIFI_IF 相同 — 錄製卡必須是另一張"
    ip link show "$REC_IF" >/dev/null 2>&1 || die "$REC_IF 不存在"
    [ "$(driver_of "$REC_IF")" = "iwlwifi" ] && \
        warn "$REC_IF 是 iwlwifi — 不關聯時 monitor 會遇到 channel context 問題"

    head_ "步驟 1/4：檢查頻道設定"
    check_tw_range || die "頻道設定不合法，先改 CHAN_FREQ / CHAN_WIDTH / CHAN_CENTER"

    local phy
    phy=$(resolve_phy); [ -z "$phy" ] && die "找不到 $REC_IF 的 phy"

    head_ "步驟 2/4：讓 $REC_IF 離開 NetworkManager"
    info "錄製卡不能連任何 AP，否則會被拉去別的頻道或開始掃描"
    sudo nmcli device disconnect "$REC_IF" >/dev/null 2>&1
    sudo nmcli device set "$REC_IF" managed no 2>/dev/null
    sudo ip link set "$REC_IF" down
    ok "$REC_IF 已停用（$phy）"

    head_ "步驟 3/4：建立 monitor 介面 $MON_IF"
    make_monitor "$phy"

    head_ "步驟 4/4：鎖定頻道"
    if [ "$CHAN_WIDTH" = "20" ]; then
        sudo iw dev "$MON_IF" set freq "$CHAN_FREQ" \
            || die "set freq 失敗"
    else
        sudo iw dev "$MON_IF" set freq "$CHAN_FREQ" "$CHAN_WIDTH" "$CHAN_CENTER" \
            || die "set freq 失敗 — 檢查中心頻率，或先退到 80 MHz：CHAN_WIDTH=80 CHAN_CENTER=6145"
    fi
    local ch
    ch=$(iw dev "$MON_IF" info 2>/dev/null | grep -E 'channel')
    info "$ch"
    if echo "$ch" | grep -q "width: ${CHAN_WIDTH} MHz"; then
        ok "已鎖定 $CHAN_FREQ MHz / $CHAN_WIDTH MHz（中心 $CHAN_CENTER）"
    else
        die "頻寬不是 ${CHAN_WIDTH} MHz — 驅動可能不支援此組合"
    fi

    head_ "完成"
    info "AX210 / iPhone 當 beamformee 正常連 AP，本卡只負責聽"
    info "下一步：./bfid.sh verify"
}

# ==================================================================
# 內部：乾淨擷取
# ==================================================================
_capture_to() {
    local out="$1" secs="$2"

    if ! ip link show "$MON_IF" >/dev/null 2>&1; then
        die "$MON_IF 不存在 — 先跑 ./bfid.sh up"
    fi

    # 殘留的 tcpdump 會跟新的搶同一個檔，把 pcap 寫爛
    if pgrep -x tcpdump >/dev/null; then
        warn "有殘留的 tcpdump，先終止"
        sudo pkill -x tcpdump; sleep 1
    fi
    rm -f "$out"
    mkdir -p "$(dirname "$out")"

    info "擷取 ${secs}s → $out"
    # -Z 讓檔案歸一般使用者所有；-U 即時寫入；-s INT 讓 tcpdump 乾淨收尾
    sudo timeout -s INT "$secs" tcpdump -i "$MON_IF" -Z "$(id -un)" -U -w "$out" 2>&1 \
        | grep -vE '^tcpdump: listening' | while read -r l; do info "$l"; done

    if [ ! -s "$out" ]; then
        bad "沒有產生檔案或檔案是空的"
        return 1
    fi
    if ! capinfos "$out" >/dev/null 2>&1; then
        bad "pcap 損壞 — 通常是有兩個 tcpdump 同時在寫"
        return 1
    fi
    return 0
}

# ==================================================================
# verify — 關卡驗證
# ==================================================================
cmd_verify() {
    check_mode
    local secs="${1:-30}"
    local pcap="$CAPTURE_DIR/_verify.pcap"

    head_ "關卡驗證（${secs} 秒，MODE=$MODE）"
    warn "請先讓 beamformee 產生流量：iPhone 播 4K 影片、跑 Speedtest，"
    warn "或從本機 iperf3 -c <iPhone_IP> -t $((secs+10)) -b 200M"
    echo
    read -r -p "  流量跑起來了就按 Enter 開始…" _ || true

    _capture_to "$pcap" "$secs" || return 1

    local total
    total=$(capinfos -c "$pcap" 2>/dev/null | awk -F': *' '/Number of packets/ {print $2}' | tr -d ' ')
    total="${total:-0}"

    head_ "結果"
    info "總封包數 $total"

    if [ "$total" -eq 0 ]; then
        bad "一個封包都沒有 — monitor 介面沒在收"
        if [ "$MODE" = "shared" ]; then
            info "多半是 channel context 問題。確認 $WIFI_IF 真的還連著："
            info "  iw dev $WIFI_IF link"
        else
            info "確認頻道：iw dev $MON_IF info；AP 真的在 $CHAN_FREQ MHz 上嗎？"
        fi
        return 1
    fi

    echo
    info "幀型態分布："
    tshark -r "$pcap" -T fields -e wlan.fc.type_subtype 2>/dev/null \
        | sort | uniq -c | sort -rn | head -10 \
        | while read -r c t; do info "  $c × $t"; done

    echo
    info "發送端分布："
    tshark -r "$pcap" -T fields -e wlan.sa 2>/dev/null \
        | grep -v '^$' | sort | uniq -c | sort -rn | head -10 \
        | while read -r c m; do info "  $c × $m"; done

    # 混雜接收是否生效：看得到目標裝置發的幀嗎
    local from_target
    from_target=$(tshark -r "$pcap" -T fields -e wlan.sa 2>/dev/null \
                  | grep -ci "$TARGET_MAC")
    echo
    if [ "$from_target" -gt 0 ]; then
        ok "抓到 $from_target 個來自目標裝置 $TARGET_MAC 的幀"
    else
        bad "完全沒抓到目標裝置 $TARGET_MAC 發出的幀"
        if [ "$MODE" = "shared" ]; then
            info "代表混雜接收沒生效 — iwlwifi 在 managed+monitor 並存下的已知限制"
        else
            info "確認 iPhone 已關閉私密 Wi-Fi 位址，且 TARGET_MAC 填的是它的真實 MAC"
        fi
    fi

    # 關鍵：CBFR（全部 vs 目標裝置）
    local cbfr_all cbfr
    cbfr_all=$(count_cbfr "$pcap")
    cbfr=$(count_cbfr "$pcap" "$TARGET_MAC")

    echo
    head_ "判定"
    info "所有客戶端的 SU CBFR：$cbfr_all；其中目標裝置：$cbfr"
    if [ "$cbfr" -gt 0 ]; then
        local rate
        rate=$(awk -v c="$cbfr" -v s="$secs" 'BEGIN{printf "%.2f", c/s}')
        ok "目標裝置 CBFR $cbfr 個，取樣率 ${rate} Hz"
        info "論文的 BFI 取樣率約 10 Hz、序列平均長度 40"
        if awk -v r="$rate" 'BEGIN{exit !(r < 3)}'; then
            warn "取樣率偏低。先把下行流量加大再測一次；仍然拉不上去就是遞送限制"
        fi
        echo
        ok "這一關過了，可以開始正式錄製：./bfid.sh capture <標籤>"
        return 0
    fi

    if [ "$cbfr_all" -gt 0 ]; then
        bad "有 CBFR，但沒有一個屬於 $TARGET_MAC"
        info "實際的 beamformee MAC："
        tshark -r "$pcap" -Y "$(cbfr_filter)" -T fields -e wlan.sa 2>/dev/null \
            | sort | uniq -c | sort -rn | while read -r c m; do info "  $c × $m"; done
        info "多半是私密 Wi-Fi 位址沒關，或 TARGET_MAC 填錯"
        return 1
    fi

    bad "沒有抓到任何 CBFR"
    echo
    info "依序排查："
    info "  1. AP 是否協商成 11be？Wi-BFI 只支援 AC 與 AX。"
    info "     tshark -r $pcap -Y 'wlan.eht' | head"
    info "  2. 換個標準的過濾條件試試（目前用 $STANDARD）："
    info "     tshark -r $pcap -Y 'wlan.vht.mimo_control.feedbacktype==SU' | head"
    info "  3. 看看 Action 幀是什麼類別（21=VHT 才是我們要的；4=Public 不是）："
    info "     tshark -r $pcap -Y 'wlan.fc.type_subtype==0x000d' \\"
    info "       -T fields -e wlan.sa -e wlan.fixed.category_code | sort | uniq -c"
    if [ "$MODE" = "shared" ]; then
        info "  4. 若 '目標裝置的幀' 那項也是 0，就是網卡做不到被動側錄。"
        info "     補一張 MT7921AU/MT7925 USB 網卡，改用 MODE=recorder。"
    fi
    return 1
}

# ==================================================================
# capture — 正式錄製
# ==================================================================
cmd_capture() {
    check_mode
    local label="${1:-}" secs="${2:-60}"
    [ -z "$label" ] && die "用法：./bfid.sh capture <標籤> [秒數]    例：capture subject_001_normal 120"

    local pcap="$CAPTURE_DIR/${label}.pcap"
    if [ -e "$pcap" ]; then
        read -r -p "  $pcap 已存在，覆蓋？[y/N] " a
        [ "$a" = "y" ] || die "取消"
    fi

    head_ "錄製 $label（${secs} 秒）"
    info "行走之間刻意停頓約 2 秒，轉換工具才切得出一次次行走"
    read -r -p "  準備好就按 Enter…" _ || true

    _capture_to "$pcap" "$secs" || return 1

    local total
    total=$(capinfos -c "$pcap" 2>/dev/null | awk -F': *' '/Number of packets/ {print $2}' | tr -d ' ')
    ok "已存檔 $pcap（$total 個封包）"

    local cbfr_all cbfr
    cbfr_all=$(count_cbfr "$pcap")
    cbfr=$(count_cbfr "$pcap" "$TARGET_MAC")
    if [ "$cbfr" -gt 0 ]; then
        ok "目標裝置 CBFR $cbfr 個（所有客戶端共 $cbfr_all 個）"
        echo
        info "接著解析（記得先 conda activate $CONDA_ENV）："
        info "  cd $WIBFI_DIR"
        info "  python main.py $pcap $STANDARD SU $ANT_CFG $CHAN_WIDTH $TARGET_MAC $cbfr \\"
        info "      V_${label} bfa_${label}"
        info "封包數 $cbfr 已按 wlan.addr==$TARGET_MAC 計算，與 main.py 一致"
    elif [ "$cbfr_all" -gt 0 ]; then
        warn "有 $cbfr_all 個 CBFR，但沒有一個屬於 $TARGET_MAC — 檢查 MAC"
    else
        warn "這次錄製沒有任何 CBFR — 先跑 ./bfid.sh verify 查原因"
    fi
}

# ==================================================================
# status / down
# ==================================================================
cmd_status() {
    check_mode
    head_ "模式"
    info "MODE=$MODE  SSID=$SSID  TARGET_MAC=$TARGET_MAC"

    head_ "介面"
    iw dev 2>/dev/null | grep -E 'Interface|type|channel' | while read -r l; do info "$l"; done

    if [ "$MODE" = "shared" ]; then
        head_ "$WIFI_IF 連線"
        if iw dev "$WIFI_IF" link 2>/dev/null | grep -q Connected; then
            iw dev "$WIFI_IF" link | grep -E 'SSID|freq|signal|bitrate' \
                | while read -r l; do info "$l"; done
        else
            warn "$WIFI_IF 沒有連線 — monitor 會因為缺少 channel context 而收不到東西"
        fi
    fi

    head_ "$MON_IF"
    if ip link show "$MON_IF" >/dev/null 2>&1; then
        ok "存在（$(phy_of "$MON_IF")）"
        ip link show "$MON_IF" | head -1 | while read -r l; do info "$l"; done
    else
        warn "不存在 — 跑 ./bfid.sh up"
    fi

    head_ "殘留行程"
    if pgrep -x tcpdump >/dev/null; then
        warn "有 tcpdump 在跑：$(pgrep -x tcpdump | tr '\n' ' ')"
    else
        ok "沒有殘留的 tcpdump"
    fi

    head_ "擷取檔"
    if ls "$CAPTURE_DIR"/*.pcap >/dev/null 2>&1; then
        ls -lh "$CAPTURE_DIR"/*.pcap | tail -10 | while read -r l; do info "$l"; done
    else
        info "（無）"
    fi
}

cmd_down() {
    check_mode
    need_sudo
    sudo pkill -x tcpdump 2>/dev/null
    sudo ip link set "$MON_IF" down 2>/dev/null
    sudo iw dev "$MON_IF" del 2>/dev/null && ok "已移除 $MON_IF" || info "$MON_IF 本來就不存在"
    if [ "$MODE" = "recorder" ] && [ -n "$REC_IF" ]; then
        sudo nmcli device set "$REC_IF" managed yes 2>/dev/null
        info "$REC_IF 已交還 NetworkManager"
    fi
}

# ==================================================================
usage() {
    sed -n '3,43p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
    doctor)  shift; cmd_doctor "$@" ;;
    setup)   shift; cmd_setup  "$@" ;;
    up)      shift; cmd_up     "$@" ;;
    verify)  shift; cmd_verify "$@" ;;
    capture) shift; cmd_capture "$@" ;;
    status)  shift; cmd_status "$@" ;;
    down)    shift; cmd_down   "$@" ;;
    ""|-h|--help|help) usage ;;
    *) bad "未知指令：$1"; echo; usage; exit 1 ;;
esac

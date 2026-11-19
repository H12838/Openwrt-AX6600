#!/bin/bash

# Apply the locally reviewed ath11k fix only to the source tree it targets.
if [[ "$WRT_SOURCE" == "ones20250/immortalwrt_ipq" ]]; then
	ATH11K_PATCH_DIR="./package/kernel/mac80211/patches/nss/ath11k"
	ATH11K_VENDOR_PATCH="$ATH11K_PATCH_DIR/244-ath11k-dp-tx-perf.patch"
	if [[ ! -f "$ATH11K_VENDOR_PATCH" ]] ||
	   ! grep -Fq 'tx completion mismatch count' "$ATH11K_VENDOR_PATCH"; then
		echo "Expected ath11k TX completion patch is missing or changed" >&2
		exit 1
	fi
	# 999-931: per-MSDU TX completion accounting; 999-932: HTT WBM status byte offset.
	# 932 按文件名顺序在 931 之后应用, 两者都只改 ath11k dp_tx.c.
	for ATH11K_FIX_NAME in \
		999-931-ath11k-account-tx-completions-per-msdu.patch \
		999-932-ath11k-fix-htt-wbm-status-offset.patch; do
		ATH11K_SRC_PATCH="$GITHUB_WORKSPACE/Patches/ath11k/$ATH11K_FIX_NAME"
		if [[ ! -f "$ATH11K_SRC_PATCH" ]]; then
			echo "Missing local ath11k patch: $ATH11K_FIX_NAME" >&2
			exit 1
		fi
		if [[ -e "$ATH11K_PATCH_DIR/$ATH11K_FIX_NAME" ]]; then
			echo "ath11k fix path already exists upstream: $ATH11K_FIX_NAME" >&2
			exit 1
		fi
		install -m 0644 "$ATH11K_SRC_PATCH" "$ATH11K_PATCH_DIR/$ATH11K_FIX_NAME" || exit 1
	done
	# 932 的补丁体必须仍是那一行字节偏移修正 (防止文件被误改/截断).
	if ! grep -Fq 'status_desc = (void *)desc + HTT_TX_WBM_COMP_STATUS_OFFSET;' \
		"$ATH11K_PATCH_DIR/999-932-ath11k-fix-htt-wbm-status-offset.patch"; then
		echo "999-932 patch body changed (expected byte-offset fix)" >&2
		exit 1
	fi
fi

apply_sed_to_matches() {
	local SEARCH_DIR=$1
	local FILE_NAME=$2
	local SED_EXPR=$3
	local MATCHES

	MATCHES=$(find "$SEARCH_DIR" -type f -name "$FILE_NAME" 2>/dev/null)
	if [ -n "$MATCHES" ]; then
		while IFS= read -r TARGET_FILE; do
			sed -i "$SED_EXPR" "$TARGET_FILE"
		done <<< "$MATCHES"
	fi
}

#移除luci-app-attendedsysupgrade
apply_sed_to_matches "./feeds/luci/collections/" "Makefile" "/attendedsysupgrade/d"

#修改默认主题
#sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#sed -i "s/luci-theme-.*$/luci-theme-bootstrap/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")

#修改immortalwrt.lan关联IP
apply_sed_to_matches "./feeds/luci/modules/luci-mod-system/" "flash.js" "s/192\\.168\\.[0-9]*\\.[0-9]*/$WRT_IP/g"
#添加编译日期标识
apply_sed_to_matches "./feeds/luci/modules/luci-mod-status/" "10_system.js" "s/(\\(luciversion || ''\\))/(\\1) + (' \\/ $WRT_MARK-$WRT_DATE')/g"

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" "$WIFI_SH"
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" "$WIFI_SH"
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改WIFI地区
	#sed -i "s/country='.*'/country='US'/g" $WIFI_UC
	#修改WIFI加密
	#sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG_FILE"
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG_FILE"

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
#echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
#echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find "$DTS_PATH" -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
fi

# =========================================================
# 智能系统调优：优化内存水位线 (min_free_kbytes)
# =========================================================

MIN_FREE_VAL=16384
CONF_FILE="./package/base-files/files/etc/sysctl.conf"

# 提取当前值（只匹配非注释、行首）
CURRENT_VAL=$(sed -n 's/^vm\.min_free_kbytes=\([0-9]\+\).*/\1/p' "$CONF_FILE")

if [ -z "$CURRENT_VAL" ]; then
    echo "" >> "$CONF_FILE"
    echo "vm.min_free_kbytes=$MIN_FREE_VAL" >> "$CONF_FILE"
    echo "Memory patch: value not found, added $MIN_FREE_VAL."
else
    if [ "$CURRENT_VAL" -lt "$MIN_FREE_VAL" ]; then
        sed -i "s/^vm\.min_free_kbytes=.*/vm.min_free_kbytes=$MIN_FREE_VAL/" "$CONF_FILE"
        echo "Memory patch: upgraded $CURRENT_VAL -> $MIN_FREE_VAL."
    else
        echo "Memory patch: current value ($CURRENT_VAL) is sufficient, skipped."
    fi
fi

SKIPUNZIP=1

# =========================================================
# Utils Functions to Extract and verify installation package

TMPDIR_FOR_VERIFY="$TMPDIR/.vunzip"
mkdir "$TMPDIR_FOR_VERIFY"

abort_verify() {
  ui_print "--------------"
  ui_print "! $1"
  ui_print "! This Zip may be Corrupted, Please Try Downloading Again"
  abort    "--------------"
}

# Usage: Extract <Zip> <File> <Target Dir> [Junk Paths: True|False]
extract() {
  local zip="$1"
  local file="$2"
  local dir="$3"
  local junk_paths="${4:-false}" # Defaults to False if Not Provided
  local opts="-o"
  local file_path hash_path file_basename

  file_basename=$(basename "$file")

  if [ "$junk_paths" = "true" ]; then
    opts="-oj"
    file_path="$dir/$file_basename"
    hash_path="${TMPDIR_FOR_VERIFY}/$file_basename.sha256"
  else
    file_path="$dir/$file"
    hash_path="${TMPDIR_FOR_VERIFY}/$file.sha256"
  fi

  # Extract the File and its Hash
  unzip $opts "$zip" "$file" -d "$dir" >/dev/null 2>&1
  [ -f "$file_path" ] || abort_verify "Extracted $file does Not Exist"

  unzip $opts "$zip" "$file.sha256" -d "${TMPDIR_FOR_VERIFY}" >/dev/null 2>&1
  [ -f "$hash_path" ] || abort_verify "Hash File $file.sha256 does Not Exist"

  # Read the Expected Hash and Verify it
  local expected_hash
  read -r expected_hash < "$hash_path"
  expected_hash="${expected_hash%% *}" # Strip Anything After the Actual Hash String

  if ! echo "$expected_hash  $file_path" | sha256sum -c -s -; then
    abort_verify "Failed to Verify $file"
  fi

  ui_print "- Verified $file"
}
# =========================================================

VERSION=$(grep_prop version "${TMPDIR}/module.prop")
ui_print "- Vector Version ${VERSION}"

# Disable Existing LSPosed Installation
LSPOSED_DIR="/data/adb/modules/zygisk_lsposed"
if [ -d "$LSPOSED_DIR" ]; then
    ui_print "--------------"
    ui_print "LSPosed Installation Detected, Disabling it for Vector"
    touch "$LSPOSED_DIR/disable"
    ui_print "--------------"
fi

# 1. Map Architecture to Standard ABI Paths, Eliminating Duplicate Logic
case "$ARCH" in
    arm|arm64)
        ABI32="armeabi-v7a"
        ABI64="arm64-v8a"
        ;;
    x86|x64)
        ABI32="x86"
        ABI64="x86_64"
        ;;
    *)
        abort "! Unsupported Platform: $ARCH"
        ;;
esac
ui_print "- Device Platform: $ARCH ($ABI32 / $ABI64)"

ui_print "- Extracting Root Module Files"
for file in module.prop action.sh service.sh uninstall.sh sepolicy.rule framework/vector.dex cli daemon.apk daemon manager.apk; do
    extract "$ZIPFILE" "$file" "$MODPATH"
done

ui_print "- Extracting Zygisk libraries"
mkdir -p "$MODPATH/zygisk"

# Extract 32-bit Lib
extract "$ZIPFILE" "lib/$ABI32/libzygisk.so" "$MODPATH/zygisk" true
mv "$MODPATH/zygisk/libzygisk.so" "$MODPATH/zygisk/${ABI32}.so"

# Extract 64-bit Lib if Supported
if [ "$IS64BIT" = true ]; then
    extract "$ZIPFILE" "lib/$ABI64/libzygisk.so" "$MODPATH/zygisk" true
    mv "$MODPATH/zygisk/libzygisk.so" "$MODPATH/zygisk/${ABI64}.so"
fi

if [ "$API" -ge 29 ]; then
    ui_print "- Extracting Dex2oat Binaries"
    mkdir -p "$MODPATH/bin"

    # Extract 32-Bit Binaries
    extract "$ZIPFILE" "bin/$ABI32/dex2oat" "$MODPATH/bin" true
    extract "$ZIPFILE" "bin/$ABI32/liboat_hook.so" "$MODPATH/bin" true
    mv "$MODPATH/bin/dex2oat" "$MODPATH/bin/dex2oat32"
    mv "$MODPATH/bin/liboat_hook.so" "$MODPATH/bin/liboat_hook32.so"

    # Extract 64-Bit Binaries
    if [ "$IS64BIT" = true ]; then
        extract "$ZIPFILE" "bin/$ABI64/dex2oat" "$MODPATH/bin" true
        extract "$ZIPFILE" "bin/$ABI64/liboat_hook.so" "$MODPATH/bin" true
        mv "$MODPATH/bin/dex2oat" "$MODPATH/bin/dex2oat64"
        mv "$MODPATH/bin/liboat_hook.so" "$MODPATH/bin/liboat_hook64.so"
    fi

    ui_print "- Patching Binaries for Anti-Detection"
    DEV_PATH=$(tr -dc 'a-z0-9' </dev/urandom | head -c 32)
    # Patch Only if the File Successfully Exists
    [ -f "$MODPATH/daemon.apk" ] && sed -i "s/5291374ceda0aef7c5d86cd2a4f6a3ac/$DEV_PATH/g" "$MODPATH/daemon.apk"
    [ -f "$MODPATH/bin/dex2oat32" ] && sed -i "s/5291374ceda0aef7c5d86cd2a4f6a3ac/$DEV_PATH/" "$MODPATH/bin/dex2oat32"
    [ -f "$MODPATH/bin/dex2oat64" ] && sed -i "s/5291374ceda0aef7c5d86cd2a4f6a3ac/$DEV_PATH/" "$MODPATH/bin/dex2oat64"
else
    extract "$ZIPFILE" 'system.prop' "$MODPATH"
fi

ui_print "- Setting Permissions"
set_perm_recursive "$MODPATH" 0 0 0755 0644
[ -d "$MODPATH/bin" ] && set_perm_recursive "$MODPATH/bin" 0 2000 0755 0755 u:object_r:xposed_file:s0

set_perm "$MODPATH/daemon" 0 0 0744
set_perm "$MODPATH/cli" 0 0 0744

if [ "$(grep_prop ro.maple.enable)" = "1" ]; then
    ui_print "- Add ro.maple.enable=0"
    echo "ro.maple.enable=0" >>"$MODPATH/system.prop"
fi

ui_print "- Welcome to Vector"

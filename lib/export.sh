# =============================================================================
# export.sh — 产物导出（xz / vmdk / ova）
# 从 raw 磁盘镜像派生；img 压缩会移除源文件，故 vmdk/ova 先行
# =============================================================================

export_vmdk() {
    info "转换 vmdk ..."
    qemu-img convert -f raw -O vmdk -o subformat=streamOptimized \
        "${RAW_FILE}" "${VMDK_FILE}"
    BUILD_ARTIFACTS+=("${VMDK_FILE}")
}

export_ova() {
    info "打包 ova ..."
    local work="${WORK_DIR}/ova.d"
    rm -rf "${work}" && mkdir -p "${work}"
    qemu-img convert -f raw -O vmdk -o subformat=streamOptimized \
        "${RAW_FILE}" "${work}/disk.vmdk"
    cat > "${work}/landscape.ovf" <<EOF
<?xml version="1.0"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1">
  <References><File ovf:href="disk.vmdk" ovf:id="file1"/></References>
  <DiskSection>
    <Disk ovf:capacity="${IMAGE_SIZE_MB}" ovf:capacityAllocationUnits="byte * 2^20"
          ovf:diskId="vmdisk1" ovf:fileRef="file1"
          ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </DiskSection>
  <VirtualSystem ovf:id="basalt">
    <Info>Landscape Router</Info>
  </VirtualSystem>
</Envelope>
EOF
    (cd "${work}" && sha256sum landscape.ovf disk.vmdk \
        | awk '{print "SHA256(" $2 ")= " $1}' > manifest.mf)
    tar --format=ustar -C "${work}" -cf "${OVA_FILE}" \
        landscape.ovf disk.vmdk manifest.mf
    rm -rf "${work}"
    BUILD_ARTIFACTS+=("${OVA_FILE}")
}

export_img_xz() {
    if [[ "${COMPRESS_OUTPUT}" == "yes" ]]; then
        info "压缩 img -> xz ..."
        xz -T0 --keep "${RAW_FILE}"
        mv "${RAW_FILE}.xz" "${IMAGE_XZ_FILE}"
        BUILD_ARTIFACTS+=("${IMAGE_XZ_FILE}")
        rm -f "${RAW_FILE}"
    else
        mv "${RAW_FILE}" "${IMAGE_RAW_FILE}"
        BUILD_ARTIFACTS+=("${IMAGE_RAW_FILE}")
    fi
}
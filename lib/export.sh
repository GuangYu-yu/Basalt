# =============================================================================
# export.sh — 产物导出（xz / vmdk / ova）
# 从 raw 磁盘镜像派生；img 压缩用 --keep 保留源 raw、压缩完成后再手动删除，
# 故 vmdk/ova 先行。OVF 按 DMTF 规范声明 NetworkSection/VirtualHardwareSection，
# 供 VMware/ESXi 导入向导直接识别网卡与硬件规格
# =============================================================================

xml_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' <<<"$1"
}

export_vmdk() {
    info "转换 vmdk ..."
    qemu-img convert -f raw -O vmdk -o subformat=streamOptimized \
        "${RAW_FILE}" "${VMDK_FILE}"
    BUILD_ARTIFACTS+=("${VMDK_FILE}")
}

export_ova() {
    info "打包 ova ..."
    local work="${WORK_DIR}/ova.d"
    local raw_size_bytes sectors_512 vm_name escaped_vm_name
    local cpu_cores=2 memory_mb=2048 nic_model="virtio" nic_desc="VirtIO ethernet adapter"
    rm -rf "${work}" && mkdir -p "${work}"
    qemu-img convert -f raw -O vmdk -o subformat=streamOptimized \
        "${RAW_FILE}" "${work}/disk.vmdk"

    raw_size_bytes=$(stat -c '%s' "${RAW_FILE}")
    sectors_512=$(( raw_size_bytes / 512 ))
    vm_name="${BUILD_NAME}"
    escaped_vm_name=$(xml_escape "${vm_name}")
    cat > "${work}/landscape.ovf" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
          xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData">
  <References>
    <File ovf:id="file1" ovf:href="disk.vmdk" ovf:size="$(stat -c '%s' "${work}/disk.vmdk")"/>
  </References>
  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:diskId="disk1" ovf:fileRef="file1"
          ovf:capacity="${sectors_512}" ovf:capacityAllocationUnits="byte * 512"
          ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </DiskSection>
  <NetworkSection>
    <Info>Logical networks</Info>
    <Network ovf:name="bridged">
      <Description>Default bridged network</Description>
    </Network>
  </NetworkSection>
  <VirtualSystem ovf:id="${escaped_vm_name}">
    <Info>Landscape Router</Info>
    <Name>${escaped_vm_name}</Name>
    <OperatingSystemSection ovf:id="96">
      <Info>Guest operating system</Info>
      <Description>Debian GNU/Linux 64-bit</Description>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>${escaped_vm_name}</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>vmx-14</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits>
        <rasd:Description>Number of Virtual CPUs</rasd:Description>
        <rasd:ElementName>${cpu_cores} virtual CPU(s)</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>${cpu_cores}</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>${memory_mb}MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>${memory_mb}</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:Address>0</rasd:Address>
        <rasd:Description>SATA Controller</rasd:Description>
        <rasd:ElementName>sataController0</rasd:ElementName>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceSubType>AHCI</rasd:ResourceSubType>
        <rasd:ResourceType>20</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:Description>Disk Drive</rasd:Description>
        <rasd:ElementName>disk1</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/disk1</rasd:HostResource>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Connection>bridged</rasd:Connection>
        <rasd:Description>${nic_desc}</rasd:Description>
        <rasd:ElementName>ethernet0</rasd:ElementName>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:ResourceSubType>${nic_model}</rasd:ResourceSubType>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
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
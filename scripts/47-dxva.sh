#!/bin/bash

if [[ ${TARGET_OS} != "windows" ]]; then
    exit 255
fi

add_enable "--enable-dxva2 --enable-d3d11va" # --enable-d3d12va"

exit 0
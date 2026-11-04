# Local RTX GPU check in Docker Desktop / WSL2

This container tests a **Linux** FFmpeg executable against the Windows host's
RTX GPU through WSL2. It cannot validate a FreeBSD executable, kernel, Vulkan
loader or GPU driver. FreeBSD needs its own machine or VM; GPU passthrough into
that VM is a separate requirement.

The image builds Mesa Dozen, a Vulkan-to-D3D12 driver, because WSL exposes
`/dev/dxg` and D3D12 rather than the normal Linux NVIDIA Vulkan kernel interface.
This is a translated Vulkan path, not FreeBSD's native NVIDIA driver path.
Mesa 25.0.7 is pinned by its [published SHA-256](https://docs.mesa3d.org/relnotes/25.0.7.html);
DirectX-Headers v1.614.1 is pinned to its full commit.
The build stage reuses this repository's existing FFmpeg base/toolchain image;
the resulting runtime stage contains no C/C++ build toolchain or Mesa source tree.

From PowerShell on the Windows host, with Docker Desktop's WSL2 GPU support:

```powershell
./tools/gpu-container/run.ps1 -Build `
  -FFmpegPath ./output/hap-apv/full-linux/ffmpeg -SystemControl `
  -LabName nomercy-gpu-rtx3070
```

The FFmpeg file is mounted read-only. `-SystemControl` additionally runs the
image's small dynamically linked FFmpeg control and labels its results separately.
That control is compiled from the repository base image's FFmpeg source with
only the required fixtures, NVENC and Vulkan filters enabled. Omitting `-FFmpegPath`
tests only that control executable, not a full NoMercy build. No driver is installed
on the Windows host or in the FFmpeg distribution.
Both `/usr/lib/wsl/lib` and `/usr/lib/wsl/drivers` are mounted read-only:
the latter supplies the D3D12 user-mode driver that CUDA-only injection omits.

The runner requires an NVIDIA adapter matching `RTX 3070` by default, a hardware
Vulkan device type, actual `scale_vulkan` execution and download of three frames,
and actual H.264 NVENC encoding. It rejects CPU adapters such as lavapipe and
llvmpipe. GPU visibility through `nvidia-smi` is recorded but cannot pass the
execution checks by itself. Missing drivers, unsupported APIs and failed GPU
work produce a nonzero exit code, with separate logs and `report.json` under
`output/gpu-container/` (override using `-ResultsDirectory`).

`-LabName` leaves the container running with no published ports, even if GPU
checks fail. Existing containers are never replaced. Inspect or repeat a check:

```powershell
docker exec nomercy-gpu-rtx3070 nvidia-smi
docker exec nomercy-gpu-rtx3070 python3 /tools/probe.py --ffmpeg /ffmpeg/ffmpeg --system-control
```

Without `-LabName` the check uses a temporary container. The adapter rejection
tests need no GPU: `python -B -m unittest discover -s tools/gpu-container`.

This is a diagnostic tool, not a guarantee that every WSL/driver combination
supports Dozen or that a statically linked FFmpeg can initialize its CUDA driver.
Keep any failed requested-build result even when the dynamic control succeeds.

Dozen exposes Vulkan 1.2. The same limitation is present in the inspected
[Mesa 26.2.4 driver](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.4/src/microsoft/vulkan/dzn_device.c).
It does not implement the `VkFormatProperties3` path used by FFmpeg 9's frame
format query. A real RTX adapter can therefore enumerate successfully while
FFmpeg's Vulkan upload/filter operation fails. The tool retains that failure;
neither a version override nor a CPU renderer is used to turn it into a pass.

Docker documents [WSL2 GPU access](https://docs.docker.com/desktop/features/gpu/)
and that [containers share their host kernel](https://docs.docker.com/get-started/docker-concepts/the-basics/what-is-a-container/).
NVIDIA's [WSL guide](https://docs.nvidia.com/cuda/wsl-user-guide/index.html)
explains the Windows-provided CUDA interface; do not install a Linux NVIDIA
kernel driver into WSL.

# FreeBSD runtime validation in Docker

This Linux container runs a real FreeBSD 14.3 kernel inside QEMU software
emulation. It validates FreeBSD startup, shared base libraries, dlopen and
CPU fallback. It does not expose the host's physical GPU to FreeBSD and
cannot establish FreeBSD Vulkan GPU correctness.

The official BASIC-CLOUDINIT UFS image is downloaded from FreeBSD's archive
and checked against both a pinned SHA-256 and the official checksum manifest.
The compressed image is about 836 MiB. The image and per-run qcow2 overlays
stay in the mounted work directory. Existing base images remain unchanged.
QEMU uses 2 GiB of guest RAM and two baseline `qemu64` CPUs; KVM is not
required. This exercises the x86_64 CPU fallback rather than emulated AVX.

Build from this directory:

```sh
docker build -t nomercy-freebsd-vm tools/freebsd-vm
```

Create a work directory, then start the container with its absolute path:

```sh
docker run -d --name nomercy-freebsd-vm --cpus 2 --memory 3g \
  --cap-drop ALL --security-opt no-new-privileges \
  --mount type=bind,source=/absolute/path/to/vm-work,target=/work \
  nomercy-freebsd-vm
docker logs -f nomercy-freebsd-vm
```

No host port is published. SSH is forwarded only on container loopback.
The SSH key is generated for this container and stored inside its runtime
directory; no existing host keys or credentials are mounted. FreeBSD's
nuageinit consumes a generated cidata ISO to configure key-only SSH access.
Host services and network settings are unchanged.

Stopping and starting the same container creates a fresh guest overlay using
the cached base image. Its container-only client key is reused, while the
guest host-key record and readiness marker are reset for the new guest.

After the log says `FreeBSD VM ready`, copy a target binary into the container
and stream it to the guest:

```sh
docker cp /absolute/path/to/freebsd-ffmpeg nomercy-freebsd-vm:/tmp/ffmpeg
docker exec nomercy-freebsd-vm sh -c \
  'cat /tmp/ffmpeg | /tools/ssh.sh "cat >/tmp/ffmpeg; chmod +x /tmp/ffmpeg"'
docker exec nomercy-freebsd-vm /tools/ssh.sh '/tmp/ffmpeg -version'
```

Guest serial output is saved to `/work/serial.log`; the kernel/userland
versions are recorded in `/work/guest-version.txt`. Shut down with:

```sh
docker exec nomercy-freebsd-vm /tools/ssh.sh 'shutdown -p now'
docker rm nomercy-freebsd-vm
```

## Real loader without a driver

`build-loader.sh` creates a test-only shared Vulkan loader and a small API
probe in `/tmp/real-vulkan-loader`. Run it inside the project's FreeBSD 14.3
cross-toolchain container, with `CC`, `CXX`, `CROSS_PREFIX` and the pinned
Vulkan-Headers 1.4.353 source at `/build/vulkan-headers`. It uses the official
Vulkan-Loader `v1.4.353` tag and verifies commit
`1025d2a5a05018b6dbb41440718af7a7f1153a94`. Tests, code generation and window
system support are disabled. The loader is not installed into the release
prefix or packaged with FFmpeg.

Copy those test artifacts into the guest at `/tmp/nm-real-vulkan-loader`,
then run:

```sh
env VK_DRIVER_FILES=/nonexistent.json VK_ICD_FILENAMES=/nonexistent.json \
  /tmp/nm-real-vulkan-loader/loader-no-driver \
  /tmp/nm-real-vulkan-loader/libvulkan.so.1
```

The probe requires successful loading of the real FreeBSD DSO and Vulkan API
version lookup, followed by `VK_ERROR_INCOMPATIBLE_DRIVER` when no ICD exists.
For an FFmpeg fallback check, set
`LD_LIBRARY_PATH=/tmp/nm-real-vulkan-loader` for that command only, with the
same nonexistent ICD paths. This fixture proves the real loader's no-driver
path; it does not test a physical GPU.

`verify-real-loader.sh LOADER_DIRECTORY FFMPEG` automates both FFmpeg paths in
the guest. It requires real-loader diagnostics and the expected missing-model
failure from whisper startup, then a clean error from an explicitly requested
Vulkan hardware device. Logs are saved under `LOADER_DIRECTORY/logs-ffmpeg`.
The expected model error deliberately stops before inference; these checks
do not establish model output parity or real GPU execution.

Primary sources:

- [Official 14.3 VM archive and checksums](https://archive.freebsd.org/old-releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/)
- [FreeBSD 14.3 BASIC-CLOUDINIT image configuration](https://github.com/freebsd/freebsd-src/blob/releng/14.3/release/tools/basic-cloudinit.conf)
- [FreeBSD 14.3 nuageinit shell user-data support](https://github.com/freebsd/freebsd-src/blob/releng/14.3/libexec/nuageinit/nuageinit)
- [Vulkan-Loader 1.4.353 build configuration](https://github.com/KhronosGroup/Vulkan-Loader/blob/v1.4.353/CMakeLists.txt)

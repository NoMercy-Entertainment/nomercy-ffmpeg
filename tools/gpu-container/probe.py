#!/usr/bin/env python3
"""Require actual GPU work; this Linux/WSL2 check cannot validate FreeBSD."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def select_hardware_device(info, expected_gpu):
    for match in re.finditer(r'(?ms)^GPU(\d+):\s*\n(.*?)(?=^GPU\d+:|\Z)', info):
        section = match.group(2)
        device_name = re.search(r'(?m)^\s*deviceName\s*=\s*(.+)$', section)
        device_type = re.search(r'(?m)^\s*deviceType\s*=\s*(.+)$', section)
        vendor = re.search(r'(?m)^\s*vendorID\s*=\s*(.+)$', section)
        if not (device_name and device_type and vendor):
            continue
        name = device_name.group(1).strip()
        kind = device_type.group(1).strip()
        hardware = any(value in kind for value in ('DISCRETE_GPU', 'INTEGRATED_GPU', 'VIRTUAL_GPU'))
        software = any(value in name.casefold() for value in ('llvmpipe', 'lavapipe', 'software', 'basic render', 'warp'))
        if expected_gpu.casefold() in name.casefold() and '10de' in vendor.group(1).casefold() and hardware and not software:
            return {'index': int(match.group(1)), 'name': name, 'type': kind}
    return None


def query_cuda(expected_gpu):
    try:
        cuda = ctypes.CDLL('libcuda.so.1')
        init = cuda.cuInit(0)
        count = ctypes.c_int()
        count_code = cuda.cuDeviceGetCount(ctypes.byref(count)) if init == 0 else -1
        name = ctypes.create_string_buffer(256)
        name_code = cuda.cuDeviceGetName(name, len(name), 0) if count_code == 0 and count.value > 0 else -1
        cuda_name = name.value.decode('utf-8', errors='replace')
        return {'passed': init == 0 and count_code == 0 and name_code == 0 and expected_gpu.casefold() in cuda_name.casefold(),
                'cuInit': init, 'device_count': count.value, 'device_0': cuda_name}
    except (OSError, AttributeError) as error:
        return {'passed': False, 'details': str(error)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffmpeg', default='/usr/local/bin/ffmpeg-control', help='Linux executable; mount a NoMercy build here')
    parser.add_argument('--expect-gpu', default='RTX 3070')
    parser.add_argument('--results', default='/results')
    parser.add_argument('--system-control', action='store_true', help='Also test the dynamic FFmpeg control, separately labelled')
    parser.add_argument('--cuda-only', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.cuda_only:
        cuda = query_cuda(args.expect_gpu)
        print(json.dumps(cuda))
        return 0 if cuda['passed'] else 1
    results = Path(args.results)
    results.mkdir(parents=True, exist_ok=True)
    Path(os.environ.get('XDG_RUNTIME_DIR', '/tmp/nm-gpu-runtime')).mkdir(mode=0o700, parents=True, exist_ok=True)
    report = {'scope': 'Linux/WSL2 only; no FreeBSD kernel or driver validation',
              'kernel': os.uname().release, 'ffmpeg': args.ffmpeg, 'checks': {}}

    def command(name, argv, timeout=90):
        try:
            process = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, errors='replace', timeout=timeout)
            output = process.stdout
            code = process.returncode
        except (OSError, subprocess.TimeoutExpired) as error:
            output = str(error)
            code = -1
        (results / (name + '.log')).write_text(output, encoding='utf-8')
        return code, output

    code, names = command('nvidia-smi', ['nvidia-smi', '--query-gpu=name,driver_version', '--format=csv,noheader'])
    visible = code == 0 and args.expect_gpu.casefold() in names.casefold()
    report['checks']['gpu_visible'] = {'passed': visible, 'details': names.strip()}
    code, cuda = command('cuda-initialization', [sys.executable, __file__, '--cuda-only', '--expect-gpu', args.expect_gpu], timeout=30)
    try:
        report['checks']['cuda_initialization'] = json.loads(cuda)
    except ValueError:
        report['checks']['cuda_initialization'] = {'passed': False, 'details': 'CUDA probe failed; see cuda-initialization.log', 'exit_code': code}

    code, info = command('vulkaninfo', ['vulkaninfo', '--summary'])
    selected = select_hardware_device(info, args.expect_gpu) if code == 0 else None
    report['checks']['vulkan_hardware_device'] = {'passed': selected is not None, 'device': selected,
                                                'details': 'Requires the named NVIDIA adapter and a hardware device type; CPU devices are rejected'}

    executables = [('requested', args.ffmpeg)]
    if args.system_control and args.ffmpeg != '/usr/local/bin/ffmpeg-control':
        executables.append(('dynamic-control', '/usr/local/bin/ffmpeg-control'))
    with tempfile.TemporaryDirectory(prefix='nm-gpu-') as temporary:
        for label, executable in executables:
            encoded = Path(temporary) / (label + '.h264')
            code, _ = command(label + '-nvenc', [executable, '-hide_banner', '-loglevel', 'verbose', '-y',
                                 '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=5', '-frames:v', '3',
                                 '-c:v', 'h264_nvenc', '-gpu', '0', '-f', 'h264', str(encoded)])
            report['checks'][label + '_nvenc_execution'] = {'passed': visible and report['checks']['cuda_initialization']['passed'] and code == 0 and encoded.is_file() and encoded.stat().st_size > 0,
                                                           'exit_code': code, 'encoder': 'h264_nvenc', 'frames': 3}
            scaled = Path(temporary) / (label + '.rgba')
            if selected:
                code, _ = command(label + '-vulkan', [executable, '-hide_banner', '-loglevel', 'verbose', '-y',
                                     '-init_hw_device', 'vulkan=gpu:' + str(selected['index']), '-filter_hw_device', 'gpu',
                                     '-f', 'lavfi', '-i', 'testsrc2=size=128x128:rate=5', '-frames:v', '3',
                                     '-vf', 'format=rgba,hwupload,scale_vulkan=w=64:h=64,hwdownload,format=rgba',
                                     '-c:v', 'rawvideo', '-pix_fmt', 'rgba', '-f', 'rawvideo', str(scaled)])
                passed = code == 0 and scaled.is_file() and scaled.stat().st_size == 64 * 64 * 4 * 3
                report['checks'][label + '_vulkan_execution'] = {'passed': passed, 'exit_code': code, 'frames': 3}
            else:
                report['checks'][label + '_vulkan_execution'] = {'passed': False, 'details': 'No verified hardware Vulkan adapter; no CPU fallback counted as success'}
    required = ['gpu_visible', 'cuda_initialization', 'vulkan_hardware_device',
                'requested_nvenc_execution', 'requested_vulkan_execution']
    report['passed'] = all(report['checks'][name]['passed'] for name in required)
    (results / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

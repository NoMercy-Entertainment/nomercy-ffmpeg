"""Exercise report gating without a GPU; mock work is not hardware evidence."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import probe


DEVICE = '''GPU0:
 vendorID = 0x10de
 deviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU
 deviceName = Microsoft Direct3D12 (NVIDIA GeForce RTX 3070)
'''


class ProbeContractTests(unittest.TestCase):
    def run_probe(self, fault=None):
        artifact_paths = []
        with tempfile.TemporaryDirectory(prefix='nm-probe-contract-') as directory:
            root = Path(directory)

            def command(argv, **kwargs):
                if argv[0] == 'nvidia-smi':
                    return subprocess.CompletedProcess(argv, 0, 'NVIDIA GeForce RTX 3070, 600.0\n')
                if '--cuda-only' in argv:
                    code = -11 if fault == 'cuda-cleanup-crash' else 0
                    payload = json.dumps({'passed': True, 'device_count': 1})
                    if fault == 'cuda-malformed-json':
                        payload = 'CUDA initialization began; incomplete report'
                    elif fault == 'cuda-non-object':
                        payload = '[]'
                    elif fault == 'cuda-non-boolean':
                        payload = json.dumps({'passed': 'false'})
                    return subprocess.CompletedProcess(argv, code, payload)
                if argv[0] == 'vulkaninfo':
                    info = DEVICE.replace('DISCRETE_GPU', 'CPU') if fault == 'cpu-adapter' else DEVICE
                    return subprocess.CompletedProcess(argv, 0, info)
                output = Path(argv[-1])
                artifact_paths.append(output)
                requested = argv[0] == '/requested-ffmpeg'
                nvenc = 'h264_nvenc' in argv
                if requested and fault == 'nvenc-crash' and nvenc:
                    return subprocess.CompletedProcess(argv, -11, 'driver initialization began\n')
                if requested and fault == 'vulkan-timeout' and not nvenc:
                    raise subprocess.TimeoutExpired(
                        argv, kwargs['timeout'], output=b'device selected before hang\xff\n',
                        stderr=b'driver cleanup pending\n')
                size = 32 if nvenc else 64 * 64 * 4 * 3
                if requested and fault == 'empty-nvenc' and nvenc:
                    size = 0
                if requested and fault == 'truncated-vulkan' and not nvenc:
                    size -= 1
                output.write_bytes(bytes(size))
                if requested and ((fault == 'nvenc-cleanup-crash' and nvenc) or
                                  (fault == 'vulkan-cleanup-crash' and not nvenc)):
                    return subprocess.CompletedProcess(argv, -11, 'output completed, then cleanup crashed\n')
                return subprocess.CompletedProcess(argv, 0, 'mock GPU operation completed\n')

            argv = ['probe.py', '--ffmpeg', '/requested-ffmpeg', '--system-control',
                    '--results', str(root / 'results')]
            with patch.object(probe.subprocess, 'run', side_effect=command), \
                 patch.object(probe.os, 'uname', return_value=SimpleNamespace(release='contract-test'), create=True), \
                 patch.object(probe.sys, 'argv', argv), \
                 patch.dict(os.environ, {'XDG_RUNTIME_DIR': str(root / 'xdg')}), \
                 contextlib.redirect_stdout(io.StringIO()):
                status = probe.main()
            report = json.loads((root / 'results/report.json').read_text())
            logs = {file.name: file.read_text() for file in (root / 'results').glob('*.log')}
            self.assertTrue(all(not file.exists() for file in artifact_paths), 'temporary output files leaked')
            return status, report, logs

    def test_complete_mock_control_flow_passes(self):
        status, report, _ = self.run_probe()
        self.assertEqual(status, 0)
        self.assertTrue(report['passed'])

    def test_dynamic_control_success_does_not_mask_requested_nvenc_crash(self):
        status, report, _ = self.run_probe('nvenc-crash')
        self.assertEqual(status, 1)
        self.assertFalse(report['checks']['requested_nvenc_execution']['passed'])
        self.assertEqual(report['checks']['requested_nvenc_execution']['exit_code'], -11)
        self.assertTrue(report['checks']['dynamic-control_nvenc_execution']['passed'])
        self.assertFalse(report['passed'])

    def test_cuda_cleanup_crash_cannot_be_masked_by_earlier_success_json(self):
        status, report, _ = self.run_probe('cuda-cleanup-crash')
        self.assertEqual(status, 1)
        self.assertFalse(report['checks']['cuda_initialization']['passed'])
        self.assertEqual(report['checks']['cuda_initialization']['exit_code'], -11)

    def test_invalid_cuda_reports_cannot_pass(self):
        for fault in ('cuda-malformed-json', 'cuda-non-object', 'cuda-non-boolean'):
            with self.subTest(fault=fault):
                status, report, _ = self.run_probe(fault)
                self.assertEqual(status, 1)
                self.assertFalse(report['checks']['cuda_initialization']['passed'])

    def test_timeout_preserves_partial_driver_logs_and_cannot_pass(self):
        status, report, logs = self.run_probe('vulkan-timeout')
        self.assertEqual(status, 1)
        self.assertFalse(report['checks']['requested_vulkan_execution']['passed'])
        self.assertEqual(report['checks']['requested_vulkan_execution']['exit_code'], 124)
        self.assertTrue(report['checks']['dynamic-control_vulkan_execution']['passed'])
        self.assertIn('device selected before hang\ufffd', logs['requested-vulkan.log'])
        self.assertIn('driver cleanup pending', logs['requested-vulkan.log'])
        self.assertIn('timed out', logs['requested-vulkan.log'])

    def test_encoded_output_cannot_mask_a_cleanup_crash(self):
        status, report, _ = self.run_probe('nvenc-cleanup-crash')
        self.assertEqual(status, 1)
        self.assertFalse(report['checks']['requested_nvenc_execution']['passed'])
        self.assertEqual(report['checks']['requested_nvenc_execution']['exit_code'], -11)

    def test_complete_download_cannot_mask_a_cleanup_crash(self):
        status, report, _ = self.run_probe('vulkan-cleanup-crash')
        self.assertEqual(status, 1)
        self.assertFalse(report['checks']['requested_vulkan_execution']['passed'])
        self.assertEqual(report['checks']['requested_vulkan_execution']['exit_code'], -11)

    def test_partial_download_is_not_three_completed_gpu_frames(self):
        status, report, _ = self.run_probe('truncated-vulkan')
        self.assertEqual(status, 1)
        self.assertFalse(report['checks']['requested_vulkan_execution']['passed'])

    def test_empty_encoder_output_is_not_gpu_work(self):
        status, report, _ = self.run_probe('empty-nvenc')
        self.assertEqual(status, 1)
        self.assertFalse(report['checks']['requested_nvenc_execution']['passed'])

    def test_matching_name_on_cpu_adapter_still_fails(self):
        status, report, _ = self.run_probe('cpu-adapter')
        self.assertEqual(status, 1)
        self.assertFalse(report['checks']['vulkan_hardware_device']['passed'])
        self.assertFalse(report['checks']['requested_vulkan_execution']['passed'])


if __name__ == '__main__':
    unittest.main()

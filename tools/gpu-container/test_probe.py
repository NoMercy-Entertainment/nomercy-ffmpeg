import unittest

from probe import select_hardware_device


def device(index=0, name='Microsoft Direct3D12 (NVIDIA GeForce RTX 3070)',
           kind='DISCRETE_GPU', vendor='0x10de'):
    return f'GPU{index}:\n\tvendorID = {vendor}\n\tdeviceType = PHYSICAL_DEVICE_TYPE_{kind}\n\tdeviceName = {name}\n'


class HardwareSelectionTests(unittest.TestCase):
    def test_expected_hardware_adapter(self):
        self.assertEqual(select_hardware_device(device(), 'RTX 3070')['index'], 0)

    def test_cpu_type_cannot_pass_even_with_expected_name(self):
        self.assertIsNone(select_hardware_device(device(kind='CPU'), 'RTX 3070'))

    def test_software_adapter_cannot_pass(self):
        self.assertIsNone(select_hardware_device(device(name='RTX 3070 llvmpipe'), 'RTX 3070'))

    def test_different_adapter_cannot_pass(self):
        self.assertIsNone(select_hardware_device(device(name='NVIDIA GeForce RTX 3090'), 'RTX 3070'))

    def test_missing_device_type_cannot_pass(self):
        self.assertIsNone(select_hardware_device('GPU0:\n vendorID = 0x10de\n deviceName = RTX 3070\n', 'RTX 3070'))

    def test_hardware_can_follow_a_software_adapter(self):
        text = device(name='llvmpipe', kind='CPU', vendor='0x10005') + device(index=1)
        self.assertEqual(select_hardware_device(text, 'RTX 3070')['index'], 1)


if __name__ == '__main__':
    unittest.main()

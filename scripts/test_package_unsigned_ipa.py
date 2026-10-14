"""Check the IPA boundary without pretending a fixture is an installable app."""
import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('ipa_packaging', Path(__file__).with_name('package_unsigned_ipa.py'))
ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ipa)


def executable(platform=2, cpu=0x0100000C):
    return struct.pack('<8I', 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, platform, 0, 0, 0)


class IPAPackagingTests(unittest.TestCase):
    def test_device_executable_accepted(self):
        ipa.device_macho(executable())

    def test_arm64_simulator_is_rejected(self):
        with self.assertRaises(ValueError):
            ipa.device_macho(executable(platform=7))

    def test_intel_simulator_is_rejected(self):
        with self.assertRaises(ValueError):
            ipa.device_macho(executable(cpu=0x01000007))

    def test_truncated_and_empty_executables_are_rejected(self):
        for data in [b'', executable()[:-1], b'not-an-app']:
            with self.subTest(length=len(data)), self.assertRaises(ValueError):
                ipa.device_macho(data)

    def fixture(self, root):
        archive = root / 'test.xcarchive'
        app = archive / 'Products/Applications/EternalMonitor.app'
        app.mkdir(parents=True)
        info = dict(CFBundleShortVersionString='0.3.0', CFBundleVersion='1001',
                    CFBundleSupportedPlatforms=['iPhoneOS'], UIDeviceFamily=[2],
                    CFBundleExecutable='EternalMonitor', CFBundleIdentifier='com.eternal.monitor')
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        (app / 'EternalMonitor').write_bytes(executable())
        (app / 'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps({}))
        return archive, app

    def test_payload_structure_and_resources_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive, app = self.fixture(root)
            (app / 'default.metallib').write_bytes(b'resource-fixture')
            output = root / 'test.ipa'
            result = ipa.package(archive, output, '0.3.0')
            with zipfile.ZipFile(output) as bundle:
                self.assertEqual(bundle.read('Payload/EternalMonitor.app/default.metallib'), b'resource-fixture')
                self.assertIsNone(bundle.testzip())
            self.assertEqual(result['files'], 4)
            self.assertEqual(len(result['sha256']), 64)

    def test_mismatched_release_fails_without_publishing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive, _ = self.fixture(root)
            with self.assertRaises(ValueError):
                ipa.package(archive, root / 'test.ipa', '0.1.0')
            self.assertFalse((root / 'test.ipa').exists())

    def test_simulator_archive_fails_without_publishing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive, app = self.fixture(root)
            (app / 'EternalMonitor').write_bytes(executable(platform=7))
            with self.assertRaises(ValueError):
                ipa.package(archive, root / 'test.ipa', '0.3.0')
            self.assertFalse((root / 'test.ipa').exists())

    def test_author_provisioning_profile_is_not_distributed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive, app = self.fixture(root)
            (app / 'embedded.mobileprovision').write_bytes(b'profile-fixture')
            with self.assertRaises(ValueError):
                ipa.package(archive, root / 'test.ipa', '0.3.0')


if __name__ == '__main__':
    unittest.main()

"""Standalone IPA packaging tests: no copyrighted/source IPA required."""
import importlib.util
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / 'package_ipa.py'
spec = importlib.util.spec_from_file_location('package_ipa', SCRIPT)
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class WidgetPackagingTests(unittest.TestCase):
    def test_embedded_widget_and_app_link_preserve_amazon_identity(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'input.ipa'
            library = root / 'lib.dylib'
            output = root / 'output.ipa'
            widget = root / 'TimbreWidgets.appex'
            widget.mkdir()
            # A thin arm64 Mach-O header with ample zeroed load-command padding.
            executable = bytearray(4096)
            executable[:4] = bytes.fromhex('cffaedfe')
            struct.pack_into('<II', executable, 16, 0, 0)
            library.write_bytes(bytes.fromhex('cffaedfe') + b'TimbreEmbeddedBuild21')
            info = {'CFBundleIdentifier': 'com.amazon.mp3.AmazonCloudPlayer',
                    'CFBundleExecutable': 'AmazonMusic',
                    'CFBundleVersion': '123',
                    'CFBundleShortVersionString': '1.2',
                    'CFBundleURLTypes': [{'CFBundleURLSchemes': ['amazonmusic']}],
                    'UISupportedDevices': ['iPhone15,2']}
            with zipfile.ZipFile(source, 'w') as out:
                out.writestr('Payload/AmazonMusic.app/Info.plist', plistlib.dumps(info))
                out.writestr('Payload/AmazonMusic.app/AmazonMusic', executable)
                out.writestr('Payload/AmazonMusic.app/PlugIns/Old.appex/Info.plist', b'dropped')
            widget_info = plistlib.loads((Path(__file__).resolve().parents[2] / 'Widget/Info.plist').read_bytes())
            (widget / 'Info.plist').write_bytes(plistlib.dumps(widget_info))
            (widget / 'TimbreWidgets').write_bytes(b'widget executable')

            packager.package(source, library, output, widget)
            with zipfile.ZipFile(output) as packaged:
                names = packaged.namelist()
                app = 'Payload/AmazonMusic.app/'
                result = plistlib.loads(packaged.read(app + 'Info.plist'))
                extension = plistlib.loads(packaged.read(app + 'PlugIns/TimbreWidgets.appex/Info.plist'))
                self.assertEqual(result['CFBundleIdentifier'], info['CFBundleIdentifier'])
                self.assertEqual(extension['CFBundleVersion'], result['CFBundleVersion'])
                self.assertEqual(extension['CFBundleIdentifier'], result['CFBundleIdentifier'] + '.TimbreWidgets')
                self.assertTrue(any('timbre-amazon' in u['CFBundleURLSchemes'] for u in result['CFBundleURLTypes']))
                self.assertTrue(any('amazonmusic' in u['CFBundleURLSchemes'] for u in result['CFBundleURLTypes']))
                self.assertNotIn(app + 'PlugIns/Old.appex/Info.plist', names)
                self.assertIn(app + 'PlugIns/TimbreWidgets.appex/TimbreWidgets', names)

    def test_invalid_widget_cannot_be_silently_embedded(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'source').write_bytes(b'source')
            (root / 'lib').write_bytes(bytes.fromhex('cffaedfe') + b'TimbreEmbeddedBuild21')
            with self.assertRaisesRegex(ValueError, 'Info.plist'):
                packager.package(root / 'source', root / 'lib', root / 'output', root / 'widget')


if __name__ == '__main__':
    unittest.main()

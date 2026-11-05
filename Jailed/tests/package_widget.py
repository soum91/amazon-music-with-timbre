"""Standalone IPA packaging tests: no copyrighted/source IPA required."""
import importlib.util
import os
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch


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
            native = bytearray(4096)
            native[:4] = bytes.fromhex('cffaedfe')
            struct.pack_into('<II', native, 16, 1, 152)
            struct.pack_into('<II', native, 32, 0x19, 152)
            struct.pack_into('<I', native, 32 + 64, 1)
            struct.pack_into('<I', native, 32 + 72 + 48, 1024)
            native[1024:1024+len(b'TimbreEmbeddedBuild21')] = b'TimbreEmbeddedBuild21'
            library.write_bytes(native)
            info = {'CFBundleIdentifier': 'com.amazon.mp3.AmazonCloudPlayer',
                    'CFBundleExecutable': 'AmazonMusic',
                    'CFBundleVersion': '123',
                    'CFBundleShortVersionString': '1.2',
                    'CFBundleURLTypes': [{'CFBundleURLSchemes': ['amznmp3']}],
                    'UISupportedDevices': ['iPhone15,2']}
            with zipfile.ZipFile(source, 'w') as out:
                out.writestr('Payload/AmazonMusic.app/Info.plist', plistlib.dumps(info))
                out.writestr('Payload/AmazonMusic.app/AmazonMusic', executable)
                out.writestr('Payload/AmazonMusic.app/PlugIns/Old.appex/Info.plist', b'dropped')
            widget_info = plistlib.loads((Path(__file__).resolve().parents[2] / 'Widget/Info.plist').read_bytes())
            (widget / 'Info.plist').write_bytes(plistlib.dumps(widget_info))
            (widget / 'TimbreWidgets').write_bytes(bytes.fromhex('cffaedfe') + bytes(128))

            # Keep this fixture independent of the release workflow's version.
            # CI sets both variables, and the marketing version takes precedence.
            with patch.dict(os.environ, {
                'TIMBRE_BUILD_VERSION': '26.37.22',
                'TIMBRE_MARKETING_VERSION': '26.37.22',
            }, clear=False):
                packager.package(source, library, output, widget)
            with zipfile.ZipFile(output) as packaged:
                names = packaged.namelist()
                app = 'Payload/AmazonMusic.app/'
                result = plistlib.loads(packaged.read(app + 'Info.plist'))
                extension = plistlib.loads(packaged.read(app + 'PlugIns/TimbreWidgets.appex/Info.plist'))
                self.assertEqual(result['CFBundleIdentifier'], info['CFBundleIdentifier'])
                self.assertEqual(extension['CFBundleVersion'], result['CFBundleVersion'])
                self.assertEqual(result['CFBundleShortVersionString'], '26.37.22')
                self.assertEqual(extension['CFBundleShortVersionString'], '26.37.22')
                self.assertEqual(extension['CFBundleIdentifier'], result['CFBundleIdentifier'] + '.TimbreWidgets')
                self.assertTrue(any('timbre-amazon' in u['CFBundleURLSchemes'] for u in result['CFBundleURLTypes']))
                self.assertTrue(any('amznmp3' in u['CFBundleURLSchemes'] for u in result['CFBundleURLTypes']))
                self.assertNotIn(app + 'PlugIns/Old.appex/Info.plist', names)
                self.assertIn(app + 'PlugIns/TimbreWidgets.appex/TimbreWidgets', names)

            # The user's known-working Timbre 19 IPA is already injected. Updating
            # the widget must never add another load command or duplicate dylib.
            retained = root / 'retained.ipa'
            packager.package(output, library, retained, widget, keep_working_library=True)
            with zipfile.ZipFile(output) as first, zipfile.ZipFile(retained) as second:
                self.assertEqual(first.read(app + 'AmazonMusic'), second.read(app + 'AmazonMusic'))
                self.assertEqual(first.read(app + 'Frameworks/TimbreNative-FlareStore.dylib'),
                                 second.read(app + 'Frameworks/TimbreNative-FlareStore.dylib'))
                self.assertEqual(second.namelist().count(app + 'Frameworks/TimbreNative-FlareStore.dylib'), 1)

            # Experimental media widget is a different installed app. The
            # original executable and DSP section bytes remain identical.
            bridge_file = root / 'TimbrePlaybackBridge.dylib'
            bridge_file.write_bytes(bytes.fromhex('cffaedfe') + bytes(64))
            lab = root / 'lab.ipa'
            packager.package(output, library, lab, widget,
                             keep_working_library=True,
                             experimental_bridge=bridge_file)
            with zipfile.ZipFile(output) as stable, zipfile.ZipFile(lab) as test:
                stable_library = stable.read(app + 'Frameworks/TimbreNative-FlareStore.dylib')
                test_library = test.read(app + 'Frameworks/TimbreNative-FlareStore.dylib')
                self.assertEqual(stable.read(app + 'AmazonMusic'), test.read(app + 'AmazonMusic'))
                self.assertEqual(stable_library[1024:], test_library[1024:])
                self.assertIn(b'@loader_path/TimbrePlaybackBridge.dylib', test_library[:1024])
                self.assertEqual(test.read(app + 'Frameworks/TimbrePlaybackBridge.dylib'),
                                 bridge_file.read_bytes())
                test_info = plistlib.loads(test.read(app + 'Info.plist'))
                ext_info = plistlib.loads(test.read(app + 'PlugIns/TimbreWidgets.appex/Info.plist'))
                self.assertEqual(test_info['CFBundleIdentifier'],
                                 'com.soum91.amazonmusictimbre.experimental')
                self.assertEqual(ext_info['CFBundleIdentifier'],
                                 test_info['CFBundleIdentifier'] + '.TimbreWidgets')
                self.assertEqual(test_info['CFBundleDisplayName'], 'Amazon Timbre Lab')
                self.assertTrue(any('timbre-amazon-lab' in t['CFBundleURLSchemes']
                                    for t in test_info['CFBundleURLTypes']))
                self.assertFalse(any('amznmp3' in t['CFBundleURLSchemes']
                                     for t in test_info['CFBundleURLTypes']))

            updated = root / 'updated.ipa'
            replacement = bytes.fromhex('cffaedfe') + b'TimbreEmbeddedBuild21 + new code'
            library.write_bytes(replacement)
            packager.package(output, library, updated, widget)
            with zipfile.ZipFile(output) as first, zipfile.ZipFile(updated) as second:
                self.assertEqual(first.read(app + 'AmazonMusic'), second.read(app + 'AmazonMusic'))
                self.assertEqual(second.read(app + 'Frameworks/TimbreNative-FlareStore.dylib'), replacement)
                self.assertEqual(second.namelist().count(app + 'Frameworks/TimbreNative-FlareStore.dylib'), 1)

    def test_invalid_widget_cannot_be_silently_embedded(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'source').write_bytes(b'source')
            (root / 'lib').write_bytes(bytes.fromhex('cffaedfe') + b'TimbreEmbeddedBuild21')
            with self.assertRaisesRegex(ValueError, 'Info.plist'):
                packager.package(root / 'source', root / 'lib', root / 'output', root / 'widget')


if __name__ == '__main__':
    unittest.main()

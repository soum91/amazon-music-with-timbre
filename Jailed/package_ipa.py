#!/usr/bin/env python3
"""Add the app-local Timbre library to a decrypted IPA; signing is external."""
import argparse
import gzip
import os
import io
import plistlib
import struct
import zipfile
from pathlib import Path


def commands(data):
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin arm64 Mach-O executable')
    offset = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        cmd, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError('Invalid Mach-O load command')
        yield cmd, offset, size
        offset += size


def inject(data):
    data = bytearray(data)
    rows = list(commands(data))
    for cmd, offset, size in rows:
        if cmd == 0x2C and struct.unpack_from('<I', data, offset + 16)[0]:
            raise ValueError('Executable must be decrypted before packaging')
    name = b'@executable_path/Frameworks/TimbreNative-FlareStore.dylib\0'
    for cmd, offset, size in rows:
        if cmd == 0xC and b'Timbre' in data[offset:offset+size]:
            raise ValueError('Timbre already injected')
    first_section = len(data)
    for cmd, offset, size in rows:
        if cmd != 0x19:
            continue
        nsects = struct.unpack_from('<I', data, offset + 64)[0]
        for i in range(nsects):
            pos = offset + 72 + i * 80
            file_offset = struct.unpack_from('<I', data, pos + 48)[0]
            if file_offset:
                first_section = min(first_section, file_offset)
    # Remove the obsolete executable signature command. The sideloading signer
    # must sign the modified executable and every nested library before install.
    kept = [bytes(data[o:o+s]) for c, o, s in rows if c != 0x1D]
    size = (24 + len(name) + 7) & ~7
    added = struct.pack('<IIIIII', 0xC, size, 24, 0, 0, 0) + name
    added += b'\0' * (size - len(added))
    payload = b''.join(kept) + added
    if 32 + len(payload) > first_section:
        raise ValueError('Insufficient header padding; no section relocation attempted')
    old_end = 32 + struct.unpack_from('<I', data, 20)[0]
    # Guard padding before altering it. Existing section bytes stay at the same offsets.
    if 32 + len(payload) > old_end and any(data[old_end:32+len(payload)]):
        raise ValueError('Header growth would overwrite nonzero data')
    data[32:max(old_end,32+len(payload))] = payload + b'\0' * max(0,old_end-32-len(payload))
    struct.pack_into('<II', data, 16, len(kept)+1, len(payload))
    return bytes(data)


def has_timbre_load_command(data):
    """Only accept the same dylib load path used by the existing working IPA."""
    name = b'@executable_path/Frameworks/TimbreNative-FlareStore.dylib\0'
    return any(cmd == 0xC and name in data[offset:offset + size]
               for cmd, offset, size in commands(data))


def package(source, library, output, widget=None, keep_working_library=False):
    raw = Path(source).read_bytes()
    if raw[:2] == b'\x1f\x8b':
        raw = gzip.decompress(raw)
    lib = Path(library).read_bytes()
    if lib[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Invalid Timbre library')
    if b'TimbreEmbeddedBuild21' not in lib:
        raise ValueError('Expected GUI 21 library marker; refusing a stale compiled library')
    widget_dir = Path(widget) if widget else None
    widget_info = None
    if widget_dir:
        widget_info_path = widget_dir / 'Info.plist'
        if not widget_info_path.is_file():
            raise ValueError('Widget extension is missing Info.plist')
        widget_info = plistlib.loads(widget_info_path.read_bytes())
        if widget_info.get('CFBundleIdentifier') != 'com.amazon.mp3.AmazonCloudPlayer.TimbreWidgets':
            raise ValueError('Widget extension bundle ID must be nested under the Amazon app')
        if widget_info.get('NSExtension', {}).get('NSExtensionPointIdentifier') != 'com.apple.widgetkit-extension':
            raise ValueError('Widget extension point is invalid')
        if widget_info.get('CFBundlePackageType') != 'XPC!':
            raise ValueError('Widget extension must be an XPC app extension bundle')
        if 'iPhoneOS' not in widget_info.get('CFBundleSupportedPlatforms', []):
            raise ValueError('Widget extension lacks an iPhoneOS platform declaration')
        widget_binary = widget_dir / widget_info.get('CFBundleExecutable', '')
        if not widget_binary.is_file():
            raise ValueError('Compiled widget executable is missing')
        if widget_binary.read_bytes()[:4] != b'\xcf\xfa\xed\xfe':
            raise ValueError('Widget executable must be an arm64 Mach-O binary')
    with zipfile.ZipFile(io.BytesIO(raw)) as original:
        candidates = [n for n in original.namelist() if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
        if len(candidates) != 1:
            raise ValueError('Expected exactly one app in Payload')
        if len(original.namelist()) != len(set(original.namelist())):
            raise ValueError('Source archive contains duplicate entries')
        info = candidates[0]
        root = info.rsplit('/', 1)[0] + '/'
        plist = plistlib.loads(original.read(info))
        if plist['CFBundleIdentifier'] != 'com.amazon.mp3.AmazonCloudPlayer':
            raise ValueError('This test adapter is only for Amazon Music')
        exe = root + plist['CFBundleExecutable']
        installed = root + 'Frameworks/TimbreNative-FlareStore.dylib'
        original_executable = original.read(exe)
        already_injected = has_timbre_load_command(original_executable)
        if keep_working_library and not already_injected:
            raise ValueError('Cannot preserve an embedded library in an original IPA')
        if already_injected and installed not in original.namelist():
            raise ValueError('Existing Timbre load command has no matching library')
        # Preserve the complete, previously verified Amazon executable when
        # repackaging a working Timbre 19 IPA. Never inject a second load command.
        modified = original_executable if already_injected else inject(original_executable)
        selected_library = original.read(installed) if keep_working_library else lib
        # Preserve Amazon identity; login uses this bundle ID. Signing is external.
        plist['CFBundleDisplayName'] = 'Amazon Music Timbre'
        plist['CFBundleName'] = 'Amazon Music Timbre'
        # The user-facing version must advance on every release. A four-part
        # build ID alone is collapsed to the same three-part display version
        # by sideloaders such as FlareStore, making updates look identical.
        version = os.environ.get('TIMBRE_BUILD_VERSION', '26.37.2')
        marketing_version = os.environ.get('TIMBRE_MARKETING_VERSION', version)
        if (len(marketing_version.split('.')) != 3 or
                not all(part.isdigit() for part in marketing_version.split('.'))):
            raise ValueError('TIMBRE_MARKETING_VERSION must have three numeric components')
        plist['CFBundleVersion'] = version
        plist['CFBundleShortVersionString'] = marketing_version
        # Keep the UI identity truthful in the preservation build. The shipped
        # library remains Build 19, even though the app build number increases.
        plist['TimbreGUIBuild'] = plist.get('TimbreGUIBuild', 19) if keep_working_library else 21
        plist['NSMotionUsageDescription'] = 'Timbre uses motion from compatible headphones to keep the spatial sound stage stable as you turn your head.'
        # A unique URL scheme allows Home/Lock Screen WidgetKit taps to foreground
        # the existing app. Do not replace Amazon's own URL registrations.
        url_types = plist.get('CFBundleURLTypes', [])
        if not isinstance(url_types, list):
            url_types = []
        if not any('timbre-amazon' in item.get('CFBundleURLSchemes', [])
                   for item in url_types if isinstance(item, dict)):
            url_types.append({'CFBundleURLName': 'com.soum91.timbre.widget',
                              'CFBundleURLSchemes': ['timbre-amazon']})
        plist['CFBundleURLTypes'] = url_types
        # App Store thinning can leave a device whitelist from the source phone.
        # Keep architectural/minimum OS requirements, but remove that whitelist.
        for key in ['UISupportedDevices', 'WKCompanionAppBundleIdentifier', 'WKWatchKitApp', 'NSExtension']:
            plist.pop(key, None)
        Path(output).parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as out:
            for entry in original.infolist():
                if not entry.filename.startswith(root):
                    continue
                # Original app/Watch extensions may be signed for a different team.
                # Remove them, then insert only our own matching widget extension.
                if any(entry.filename.startswith(root+prefix) for prefix in ['PlugIns/', 'Watch/', 'com.apple.WatchPlaceholder/', 'AppClips/']):
                    continue
                if '/_CodeSignature/' in entry.filename or '/SC_Info/' in entry.filename or entry.filename.endswith('embedded.mobileprovision'):
                    continue
                if entry.filename == installed:
                    continue
                content = modified if entry.filename == exe else plistlib.dumps(plist) if entry.filename == info else original.read(entry)
                out.writestr(entry, content, compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
            item = zipfile.ZipInfo(root + 'Frameworks/TimbreNative-FlareStore.dylib')
            item.create_system = 3
            item.external_attr = 0o100755 << 16
            out.writestr(item, selected_library, compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
            if widget_dir:
                widget_info['CFBundleVersion'] = plist['CFBundleVersion']
                widget_info['CFBundleShortVersionString'] = plist.get('CFBundleShortVersionString', '1.0')
                widget_root = root + 'PlugIns/TimbreWidgets.appex/'
                for path in sorted(widget_dir.rglob('*')):
                    if not path.is_file():
                        continue
                    relative = path.relative_to(widget_dir).as_posix()
                    if relative.startswith('_CodeSignature/') or relative == 'embedded.mobileprovision':
                        continue
                    data = plistlib.dumps(widget_info) if relative == 'Info.plist' else path.read_bytes()
                    widget_entry = zipfile.ZipInfo(widget_root + relative)
                    widget_entry.create_system = 3
                    widget_entry.external_attr = (0o100755 if relative == widget_info['CFBundleExecutable'] else 0o100644) << 16
                    out.writestr(widget_entry, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
    with zipfile.ZipFile(output) as out:
        if out.testzip():
            raise ValueError('ZIP integrity check failed')
        packaged_executable = out.read(exe)
        parsed = list(commands(packaged_executable))
        assert any(c == 0xC and b'TimbreNative-FlareStore.dylib' in packaged_executable[o:o+s] for c,o,s in parsed)
        assert out.read(installed) == selected_library
        assert sum(n == installed for n in out.namelist()) == 1
        assert has_timbre_load_command(packaged_executable)
        if already_injected:
            assert packaged_executable == original_executable
        extension = root + 'PlugIns/TimbreWidgets.appex/'
        if widget_dir:
            assert extension + widget_info['CFBundleExecutable'] in out.namelist()
            assert plistlib.loads(out.read(extension + 'Info.plist'))['CFBundleVersion'] == plist['CFBundleVersion']
            assert plistlib.loads(out.read(extension + 'Info.plist'))['CFBundleShortVersionString'] == plist['CFBundleShortVersionString']
        else:
            assert not any('.appex/' in n for n in out.namelist())
        assert not any('/com.apple.WatchPlaceholder/' in n for n in out.namelist())
        verified = plistlib.loads(out.read(info))
        assert verified['CFBundleIdentifier'] == 'com.amazon.mp3.AmazonCloudPlayer'
        assert verified['CFBundleVersion'] == plist['CFBundleVersion']
        assert 'UISupportedDevices' not in verified
    return {'output': str(Path(output).resolve()), 'bytes': Path(output).stat().st_size, 'build': plist['CFBundleVersion'], 'bundle_id': plist['CFBundleIdentifier'], 'signing_required': True}


if __name__ == '__main__':
    import json
    p = argparse.ArgumentParser()
    p.add_argument('source'); p.add_argument('library'); p.add_argument('output')
    p.add_argument('--widget', help='Compiled TimbreWidgets.appex directory to embed')
    p.add_argument('--keep-working-library', action='store_true',
                   help='Keep the existing Timbre dylib from a previously injected IPA')
    args = p.parse_args()
    print(json.dumps(package(args.source, args.library, args.output, args.widget,
                             args.keep_working_library)))



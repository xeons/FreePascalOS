#!/usr/bin/env python3
# FreePascalOS
# Copyright (C) 2026 Brandon Scott
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""Copies the freely licensed fonts the build machine has into the
system's font directory (/lib/fonts on the system disk).

    collect-host-fonts.py LIST OUTPUT [--set full|core|none]

LIST (scripts/host-fonts.list) names every family: its files, the
host package they come from and their licence. A family is copied
only if its licence file is there and says what the list expects, and
every font's own copyright or licence description (the name table's
IDs 0 and 13) does too; anything missing or not matching is skipped
with a message, never failing the build (the system works with the
fonts kept in userland/fonts alone).

Each family goes into OUTPUT/<family>/ with a LICENSE file: where the
fonts come from, their copyright and licence as they state them, and
the licence's full text. OUTPUT/MANIFEST lists every family copied
(family, directory, files, licence, package). The files copied are
remembered in OUTPUT/.host-fonts so that the next run removes them
first (families from userland/fonts are left alone).
"""

import configparser
import os
import shutil
import struct
import subprocess
import sys

RECORD_NAME = '.host-fonts'


def read_names(path):
    """The name table's strings (by ID) of a font, or of a collection's
    first face; {} if it cannot be read."""
    try:
        with open(path, 'rb') as handle:
            data = handle.read()
    except OSError:
        return {}
    try:
        offset = 0
        if data[:4] == b'ttcf':
            offset = struct.unpack('>I', data[12:16])[0]
        count = struct.unpack('>H', data[offset + 4:offset + 6])[0]
        name_table = None
        for index in range(count):
            entry = offset + 12 + 16 * index
            tag, _, table_offset, _ = struct.unpack('>4sIII', data[entry:entry + 16])
            if tag == b'name':
                name_table = table_offset
        if name_table is None:
            return {}
        _, record_count, strings = struct.unpack('>HHH', data[name_table:name_table + 6])
        names = {}
        for index in range(record_count):
            entry = name_table + 6 + 12 * index
            platform, _, language, name_id, length, start = struct.unpack('>HHHHHH', data[entry:entry + 12])
            raw = data[name_table + strings + start:name_table + strings + start + length]
            if platform == 3 and language == 0x409:
                names[name_id] = raw.decode('utf-16-be', 'replace')
            elif platform == 1 and name_id not in names:
                names[name_id] = raw.decode('latin-1')
        return names
    except (struct.error, IndexError):
        return {}


def package_version(package):
    """The installed version of a host package ('' if unknown)."""
    try:
        result = subprocess.run(['pacman', '-Q', package], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ''
    if result.returncode != 0:
        return ''
    parts = result.stdout.split()
    return parts[1] if len(parts) == 2 else ''


def family_directory(name):
    return name.strip().lower().replace(' ', '-')


def lines_of(value):
    return [line.strip() for line in value.splitlines() if line.strip()]


def remove_previous(output):
    record = os.path.join(output, RECORD_NAME)
    if not os.path.exists(record):
        return
    with open(record) as handle:
        for line in handle:
            path = os.path.join(output, line.strip())
            if line.strip() and os.path.isfile(path):
                os.remove(path)
    for entry in sorted(os.listdir(output)):
        directory = os.path.join(output, entry)
        if os.path.isdir(directory) and not os.listdir(directory):
            os.rmdir(directory)
    os.remove(record)


def license_text(section, source_root):
    """The licence's full text (the note first), and the file it came
    from; (None, reason) if it is missing or does not match."""
    chosen = None
    for candidate in lines_of(section.get('license-files', '')):
        if os.path.isfile(candidate):
            chosen = candidate
            break
    if chosen is None:
        return None, 'no licence file (%s)' % ', '.join(lines_of(section.get('license-files', '')))
    with open(chosen, encoding='utf-8', errors='replace') as handle:
        text = handle.read()
    marker = section.get('license-marker', '')
    if marker and marker.lower() not in text.lower():
        return None, 'licence file %s does not say "%s"' % (chosen, marker)
    note = section.get('license-note', '')
    if note:
        note_path = os.path.join(source_root, note)
        if not os.path.isfile(note_path):
            return None, 'licence note %s missing' % note
        with open(note_path, encoding='utf-8') as handle:
            text = handle.read().rstrip() + '\n\n' + '-' * 72 + '\nCOPYING:\n\n' + text
    return (text, chosen), None


def font_states_license(path, marker):
    names = read_names(path)
    stated = (names.get(0, '') + '\n' + names.get(13, '')).lower()
    return marker.lower() in stated, names


def write_license(directory, family, section, files, names, text, source, version):
    lines = []
    lines.append('%s' % family)
    lines.append('')
    lines.append('Files: %s' % ', '.join(os.path.basename(path) for path in files))
    lines.append('Licence: %s' % section.get('license', ''))
    package = section.get('package', '')
    lines.append('Copied from the build machine\'s package %s%s' % (package, (' ' + version) if version else ''))
    if section.get('upstream'):
        lines.append('Upstream: %s' % section.get('upstream'))
    if names.get(0):
        lines.append('')
        lines.append('Copyright (as the font states it):')
        lines.append(names[0].strip())
    if names.get(13):
        lines.append('')
        lines.append('Licence (as the font states it):')
        lines.append(names[13].strip())
    lines.append('')
    lines.append('=' * 72)
    lines.append('The licence\'s full text (from %s):' % source)
    lines.append('')
    with open(os.path.join(directory, 'LICENSE'), 'w', encoding='utf-8') as handle:
        handle.write('\n'.join(lines) + '\n' + text)


def collect(list_path, output, font_set):
    source_root = os.path.dirname(os.path.dirname(os.path.abspath(list_path)))
    os.makedirs(output, exist_ok=True)
    remove_previous(output)
    if font_set == 'none':
        print('host fonts: none wanted (HOST_FONT_SET=none)')
        return
    parser = configparser.ConfigParser(interpolation=None)
    parser.read(list_path)
    copied = []
    manifest = []
    total = 0
    skipped = 0
    for section_name in parser.sections():
        section = parser[section_name]
        if font_set not in section.get('sets', 'full').split():
            continue
        files = lines_of(section.get('files', ''))
        if font_set == 'core' and section.get('core-files'):
            files = lines_of(section.get('core-files'))
        present = [path for path in files if os.path.isfile(path)]
        missing = [path for path in files if not os.path.isfile(path)]
        if missing:
            print('host fonts: %s: not on this machine: %s' % (section_name, ', '.join(missing)))
        if not present:
            print('host fonts: %s skipped (install %s to have it)' % (section_name, section.get('package', '?')))
            skipped += 1
            continue
        licence, reason = license_text(section, source_root)
        if licence is None:
            print('host fonts: %s skipped: %s' % (section_name, reason))
            skipped += 1
            continue
        text, source = licence
        marker = section.get('name-marker', '')
        groups = {}
        refused = False
        for path in present:
            states, names = font_states_license(path, marker) if marker else (True, read_names(path))
            if not states:
                print('host fonts: %s skipped: %s does not state "%s" in its name table' %
                      (section_name, path, marker))
                refused = True
                break
            if section.getboolean('split', False):
                family = names.get(16) or names.get(1) or os.path.splitext(os.path.basename(path))[0]
            else:
                family = section.get('name', section_name)
            groups.setdefault(family, []).append((path, names))
        if refused:
            skipped += 1
            continue
        version = package_version(section.get('package', ''))
        for family, members in groups.items():
            directory_name = section_name if not section.getboolean('split', False) else family_directory(family)
            directory = os.path.join(output, directory_name)
            os.makedirs(directory, exist_ok=True)
            paths = [path for path, _ in members]
            for path in paths:
                target = os.path.join(directory, os.path.basename(path))
                shutil.copyfile(path, target)
                copied.append(os.path.join(directory_name, os.path.basename(path)))
                total += os.path.getsize(path)
            if not os.path.exists(os.path.join(directory, 'LICENSE')):
                write_license(directory, family, section, paths, members[0][1], text, source, version)
                copied.append(os.path.join(directory_name, 'LICENSE'))
            manifest.append('\t'.join([family, directory_name, ' '.join(os.path.basename(p) for p in paths),
                                       section.get('license', ''),
                                       section.get('package', '') + ((' ' + version) if version else '')]))
    with open(os.path.join(output, 'MANIFEST'), 'w', encoding='utf-8') as handle:
        handle.write('# The fonts copied from the build machine (scripts/collect-host-fonts.py):\n')
        handle.write('# family\tdirectory\tfiles\tlicence\tpackage\n')
        handle.write('\n'.join(manifest) + '\n')
    copied.append('MANIFEST')
    with open(os.path.join(output, RECORD_NAME), 'w') as handle:
        handle.write('\n'.join(copied) + '\n')
    print('host fonts (%s set): %d families, %.1f MB copied%s' %
          (font_set, len(manifest), total / 1e6, ('; %d skipped' % skipped) if skipped else ''))


def main():
    arguments = sys.argv[1:]
    font_set = 'full'
    if '--set' in arguments:
        position = arguments.index('--set')
        font_set = arguments[position + 1]
        del arguments[position:position + 2]
    if len(arguments) != 2 or font_set not in ('full', 'core', 'none'):
        print(__doc__)
        sys.exit(2)
    collect(arguments[0], arguments[1], font_set)


if __name__ == '__main__':
    main()

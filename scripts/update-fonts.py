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

"""Refreshes the fonts kept in the source tree (userland/fonts) from
the machine's font packages; run by hand (make update-fonts), never by
the build.

    update-fonts.py LIST FONTS-DIRECTORY

LIST (scripts/fonts.list) names every family: its files, the host
package they come from and their licence. A family is taken only if
all its files are there, its licence file is there and says what the
list expects, and every font's own copyright or licence description
(the name table's IDs 0 and 13) does too; anything missing or not
matching is skipped with a message, and the copy already in the source
tree is left as it is.

Each family goes into FONTS-DIRECTORY/<family>/ with a LICENSE file
(where the fonts come from, their copyright and licence as they state
them, and the licence's full text) and a SOURCE line (upstream,
version, package). FONTS-DIRECTORY/MANIFEST lists every family
(family, directory, files, licence, version, package); its rows for
families not refreshed are kept. Font files in a refreshed family's
directory that the list no longer names are removed.
"""

import os
import shutil
import subprocess
import sys

import fontlist


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


def license_text(section, source_root):
    """The licence's full text (the note first), and the file it came
    from; (None, reason) if it is missing or does not match."""
    candidates = fontlist.lines_of(section.get('license-files', ''))
    chosen = None
    for candidate in candidates:
        if os.path.isfile(candidate):
            chosen = candidate
            break
    if chosen is None:
        return None, 'no licence file (%s)' % ', '.join(candidates)
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
    names = fontlist.read_names(path)
    stated = (names.get(0, '') + '\n' + names.get(13, '')).lower()
    return marker.lower() in stated, names


def write_license(directory, family, section, files, names, text, source, version):
    lines = [family, '']
    lines.append('Files: %s' % ', '.join(sorted(files)))
    lines.append('Licence: %s' % section.get('license', ''))
    package = section.get('package', '')
    lines.append('Taken from the Arch Linux package %s%s' % (package, (' ' + version) if version else ''))
    if section.get('upstream'):
        lines.append('Upstream: %s' % section.get('upstream'))
    if names.get(0):
        lines += ['', 'Copyright (as the font states it):', names[0].strip()]
    if names.get(13):
        lines += ['', 'Licence (as the font states it):', names[13].strip()]
    lines += ['', '=' * 72, 'The licence\'s full text (from %s):' % source, '']
    with open(os.path.join(directory, 'LICENSE'), 'w', encoding='utf-8') as handle:
        handle.write('\n'.join(lines) + '\n' + text)


def write_source(directory, section, version, names):
    font_version = names.get(5, '').strip()
    line = 'upstream %s; version %s%s; package %s (Arch Linux)\n' % (
        section.get('upstream', '?'), version or '?', (' (font: %s)' % font_version) if font_version else '',
        section.get('package', '?'))
    with open(os.path.join(directory, 'SOURCE'), 'w', encoding='utf-8') as handle:
        handle.write(line)


def check_section(section_name, section, source_root):
    """The section's directories ({directory: (family, [(path, names)])})
    and its licence, or None (with a message) when it is skipped."""
    files = fontlist.files_for_set(section, None)
    missing = [path for path in files if not os.path.isfile(path)]
    if missing:
        print('update fonts: %s skipped, not on this machine: %s (install %s)' %
              (section_name, ', '.join(missing), section.get('package', '?')))
        return None
    licence, reason = license_text(section, source_root)
    if licence is None:
        print('update fonts: %s skipped: %s' % (section_name, reason))
        return None
    marker = section.get('name-marker', '')
    directories = {}
    for path in files:
        if marker:
            states, names = font_states_license(path, marker)
        else:
            states, names = True, fontlist.read_names(path)
        if not states:
            print('update fonts: %s skipped: %s does not state "%s" in its name table' %
                  (section_name, path, marker))
            return None
        if fontlist.is_split(section):
            family = fontlist.split_family(names, path)
            directory = fontlist.family_directory(family)
        else:
            family = section.get('name', section_name)
            directory = section_name
        directories.setdefault(directory, (family, []))[1].append((path, names))
    return directories, licence


def refresh_directory(fonts_directory, directory_name, family, section, members, licence, version):
    directory = os.path.join(fonts_directory, directory_name)
    os.makedirs(directory, exist_ok=True)
    wanted = set()
    for path, _ in members:
        wanted.add(os.path.basename(path))
        shutil.copyfile(path, os.path.join(directory, os.path.basename(path)))
    for entry in os.listdir(directory):
        if entry.lower().endswith(fontlist.FONT_EXTENSIONS) and entry not in wanted:
            print('update fonts: %s/%s removed (no longer in the list)' % (directory_name, entry))
            os.remove(os.path.join(directory, entry))
    text, source = licence
    names = members[0][1]
    write_license(directory, family, section, wanted, names, text, source, version)
    write_source(directory, section, version, names)
    return [family, directory_name, ' '.join(sorted(wanted)), section.get('license', ''), version or '?',
            section.get('package', '')]


def update(list_path, fonts_directory):
    source_root = os.path.dirname(os.path.dirname(os.path.abspath(list_path)))
    parser = fontlist.read_list(list_path)
    manifest = fontlist.read_manifest(fonts_directory)
    gathered = {}
    skipped = 0
    for section_name in parser.sections():
        section = parser[section_name]
        checked = check_section(section_name, section, source_root)
        if checked is None:
            skipped += 1
            continue
        directories, licence = checked
        for directory_name, (family, members) in directories.items():
            if directory_name in gathered:
                known = {os.path.basename(path) for path, _ in gathered[directory_name][2]}
                members = gathered[directory_name][2] + [m for m in members if os.path.basename(m[0]) not in known]
            gathered[directory_name] = (family, section, members, licence)
    total = 0
    for directory_name in sorted(gathered):
        family, section, members, licence = gathered[directory_name]
        version = package_version(section.get('package', ''))
        manifest[directory_name] = refresh_directory(fonts_directory, directory_name, family, section, members,
                                                     licence, version)
        total += sum(os.path.getsize(path) for path, _ in members)
    fontlist.write_manifest(fonts_directory, manifest)
    print('update fonts: %d families refreshed, %.1f MB%s' %
          (len(gathered), total / 1e6, ('; %d sections skipped' % skipped) if skipped else ''))


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    update(sys.argv[1], sys.argv[2])


if __name__ == '__main__':
    main()

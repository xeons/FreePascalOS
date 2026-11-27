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

"""The font list (scripts/fonts.list) and what update-fonts.py and
install-fonts.py share: reading the list, the files a set takes, a
font's name table, and the fonts' MANIFEST."""

import configparser
import os
import struct

FONT_EXTENSIONS = ('.ttf', '.otf', '.ttc')
MANIFEST_NAME = 'MANIFEST'
MANIFEST_HEADER = ('# The fonts in userland/data/fonts (scripts/fonts.list, scripts/update-fonts.py):\n'
                   '# family\tdirectory\tfiles\tlicence\tversion\tpackage\n')


def read_list(list_path):
    parser = configparser.ConfigParser(interpolation=None)
    parser.read(list_path)
    return parser


def lines_of(value):
    return [line.strip() for line in value.splitlines() if line.strip()]


def section_sets(section):
    return section.get('sets', 'full').split()


def files_for_set(section, font_set):
    """The files (host paths, as the list names them) a section gives
    the set: its "<set>-files" if it has them, else all its files; []
    when the section is not in the set. font_set None means every file."""
    if font_set is None:
        return lines_of(section.get('files', ''))
    if font_set not in section_sets(section):
        return []
    chosen = section.get(font_set + '-files', '')
    if chosen:
        return lines_of(chosen)
    return lines_of(section.get('files', ''))


def is_split(section):
    return section.getboolean('split', False)


def family_directory(name):
    return name.strip().lower().replace(' ', '-')


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


def split_family(names, path):
    """The family a file of a split section is (its own directory)."""
    return names.get(16) or names.get(1) or os.path.splitext(os.path.basename(path))[0]


def read_manifest(fonts_directory):
    """The MANIFEST's rows by directory (each a list of its columns)."""
    rows = {}
    path = os.path.join(fonts_directory, MANIFEST_NAME)
    if not os.path.isfile(path):
        return rows
    with open(path, encoding='utf-8') as handle:
        for line in handle:
            if line.startswith('#') or not line.strip():
                continue
            columns = line.rstrip('\n').split('\t')
            if len(columns) >= 2:
                rows[columns[1]] = columns
    return rows


def write_manifest(directory, rows, header=MANIFEST_HEADER):
    with open(os.path.join(directory, MANIFEST_NAME), 'w', encoding='utf-8') as handle:
        handle.write(header)
        for key in sorted(rows):
            handle.write('\t'.join(rows[key]) + '\n')

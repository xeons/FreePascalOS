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

"""Puts a set of the fonts kept in the source tree into the system's
font directory (/lib/fonts on the system disk).

    install-fonts.py LIST FONTS-DIRECTORY OUTPUT --set full|core|base

LIST (scripts/fonts.list) says which families and files each set
takes (a section's "sets", and its "<set>-files" when it gives the set
only some of its files); the files are taken from FONTS-DIRECTORY
(userland/data/fonts), each family's directory with its LICENSE and SOURCE,
never from the machine's own fonts. A file the list names that is not
in FONTS-DIRECTORY, or a family without its LICENSE, stops the build.

OUTPUT/<family>/ gets the files, OUTPUT/MANIFEST the set's rows of the
source tree's MANIFEST. What was put in is remembered in
OUTPUT/.installed-fonts so that the next run removes it first (other
things in OUTPUT, such as the Terminus fonts, are left alone).
"""

import os
import shutil
import sys

import fontlist

RECORD_NAME = '.installed-fonts'
# What the build used to copy from the machine's own fonts.
EARLIER_RECORD_NAMES = ('.host-fonts',)
SETS = ('full', 'core', 'base')


def remove_recorded(output, record_name):
    record = os.path.join(output, record_name)
    if not os.path.exists(record):
        return
    with open(record) as handle:
        for line in handle:
            path = os.path.join(output, line.strip())
            if line.strip() and os.path.isfile(path):
                os.remove(path)
    os.remove(record)


def remove_previous(output):
    for record_name in (RECORD_NAME,) + EARLIER_RECORD_NAMES:
        remove_recorded(output, record_name)
    for entry in sorted(os.listdir(output)):
        directory = os.path.join(output, entry)
        if os.path.isdir(directory) and not os.listdir(directory):
            os.rmdir(directory)


def index_fonts(fonts_directory):
    """Every font file in the source tree by its name: its family's directory."""
    index = {}
    for directory in sorted(os.listdir(fonts_directory)):
        path = os.path.join(fonts_directory, directory)
        if not os.path.isdir(path):
            continue
        for entry in os.listdir(path):
            if entry.lower().endswith(fontlist.FONT_EXTENSIONS):
                index[entry] = directory
    return index


def chosen_files(parser, index, font_set):
    """{directory: [file names]} the set takes; exits naming what is missing."""
    chosen = {}
    missing = []
    for section_name in parser.sections():
        for path in fontlist.files_for_set(parser[section_name], font_set):
            name = os.path.basename(path)
            if name not in index:
                missing.append('%s (%s)' % (name, section_name))
                continue
            files = chosen.setdefault(index[name], [])
            if name not in files:
                files.append(name)
    if missing:
        sys.exit('install-fonts.py: not in the source tree: %s (scripts/update-fonts.py brings them)' %
                 ', '.join(missing))
    return chosen


def install(list_path, fonts_directory, output, font_set):
    parser = fontlist.read_list(list_path)
    chosen = chosen_files(parser, index_fonts(fonts_directory), font_set)
    os.makedirs(output, exist_ok=True)
    remove_previous(output)
    source_manifest = fontlist.read_manifest(fonts_directory)
    manifest = {}
    installed = []
    total = 0
    for directory, files in sorted(chosen.items()):
        source = os.path.join(fonts_directory, directory)
        if not os.path.isfile(os.path.join(source, 'LICENSE')):
            sys.exit('install-fonts.py: %s has no LICENSE' % source)
        target = os.path.join(output, directory)
        os.makedirs(target, exist_ok=True)
        extras = [name for name in ('LICENSE', 'SOURCE') if os.path.isfile(os.path.join(source, name))]
        for name in files + extras:
            shutil.copyfile(os.path.join(source, name), os.path.join(target, name))
            installed.append(os.path.join(directory, name))
            total += os.path.getsize(os.path.join(source, name))
        row = list(source_manifest.get(directory, [directory, directory, '', '', '', '']))
        row[2] = ' '.join(sorted(files))
        manifest[directory] = row
    fontlist.write_manifest(output, manifest,
                            '# The system\'s fonts (the %s set of userland/data/fonts, scripts/fonts.list):\n'
                            '# family\tdirectory\tfiles\tlicence\tversion\tpackage\n' % font_set)
    installed.append(fontlist.MANIFEST_NAME)
    with open(os.path.join(output, RECORD_NAME), 'w') as handle:
        handle.write('\n'.join(installed) + '\n')
    print('fonts (%s set): %d families, %.1f MB' % (font_set, len(chosen), total / 1e6))


def main():
    arguments = sys.argv[1:]
    font_set = 'full'
    if '--set' in arguments:
        position = arguments.index('--set')
        font_set = arguments[position + 1]
        del arguments[position:position + 2]
    if len(arguments) != 3 or font_set not in SETS:
        print(__doc__)
        sys.exit(2)
    install(arguments[0], arguments[1], arguments[2], font_set)


if __name__ == '__main__':
    main()

#!/bin/sh
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

# Plays Doom music through the doomgeneric port's OPL path on the build
# machine (music_check.c) into WAV files in build/doom-music-check/, and
# checks they are not silent. Needs the port's patched sources
# (scripts/ports.py patch doomgeneric) and Freedoom's distfile.
#
#   tools/DoomMusicCheck/run.sh [LUMP [SECONDS]]

set -e
root=$(cd "$(dirname "$0")/../.." && pwd)
lump=${1:-D_E1M1}
seconds=${2:-20}
output=$root/build/doom-music-check
port=$root/ports/games/doomgeneric
tree=$(ls -d "$root"/build/amd64/ports/doomgeneric/work/doomgeneric-*/ 2>/dev/null | head -n 1)
distfiles=${DISTDIR:-$HOME/Downloads/sources}
if [ -z "$tree" ] || [ ! -d "$tree/chocolate-doom" ]; then
	echo "run: scripts/ports.py patch doomgeneric first" >&2
	exit 2
fi
engine=$tree/doomgeneric
chocolate=$(ls -d "$tree"/chocolate-doom/chocolate-doom-*/ | head -n 1)
mkdir -p "$output/music"

if [ ! -f "$output/freedoom1.wad" ]; then
	python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    name = next(n for n in archive.namelist() if n.endswith("/freedoom1.wad"))
    open(sys.argv[2], "wb").write(archive.read(name))' \
		"$distfiles/freedoom-0.13.0.zip" "$output/freedoom1.wad"
fi

cp "$chocolate/src/i_oplmusic.c" "$chocolate/src/midifile.c" "$chocolate/src/midifile.h" "$output/music/"
defines="-D__freepascalos__ -DNORMALUNIX -DLINUX -D_DEFAULT_SOURCE -DFEATURE_SOUND"
upstream="-std=gnu99 -O2 -fcommon -w $defines -I$engine -I$chocolate/opl"
ours="-std=gnu99 -O2 -Wall -Wextra $defines -I$engine -I$chocolate/opl -I$port/files"
objects=
compile() { # NAME SOURCE FLAGS...
	name=$1 source=$2
	shift 2
	cc "$@" -c "$source" -o "$output/$name.o"
	objects="$objects $output/$name.o"
}
compile i_oplmusic "$output/music/i_oplmusic.c" $upstream -I"$output/music" -include "$port/files/chocolate_doom_compat.h"
compile midifile "$output/music/midifile.c" $upstream -I"$output/music" -include "$port/files/chocolate_doom_compat.h"
compile opl "$chocolate/opl/opl.c" $upstream
compile opl_queue "$chocolate/opl/opl_queue.c" $upstream
compile opl3 "$chocolate/opl/opl3.c" $upstream
compile mus2mid "$engine/mus2mid.c" $upstream
compile memio "$engine/memio.c" $upstream
compile opl_freepascalos "$port/files/opl_freepascalos.c" $ours
compile music "$port/files/doomgeneric_freepascalos_music.c" $ours
compile music_check "$root/tools/DoomMusicCheck/music_check.c" $ours
cc -o "$output/music_check" $objects -lm

cd "$output"
TMPDIR=$output ./music_check freedoom1.wad "$lump" "$seconds" 48000 -opl3 "$lump-opl3-48000.wav"
TMPDIR=$output ./music_check freedoom1.wad "$lump" "$seconds" 44100 "" "$lump-opl2-44100.wav"

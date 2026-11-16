{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  What the compressing and decompressing classes share: the wrappers
  around deflate data and the compression levels.
}
unit Compression.Formats;

{$mode objfpc}
{$H+}

interface

type
  TCompressionFormat = (
    { Bare deflate data (RFC 1951), as in zip files. }
    FormatRaw,
    { zlib (RFC 1950), as in PNG and HTTP's "deflate". }
    FormatZlib,
    { gzip (RFC 1952), as in .gz files and HTTP's "gzip". }
    FormatGzip,
    { Decompressing only: gzip if the data starts with its magic,
      otherwise zlib. }
    FormatAutomatic
  );

const
  { Levels 0 to 9, as zlib's: 0 stores, 1 to 3 match greedily, 4 to 9
    look one position ahead for a longer match and search further. }
  CompressionLevelStore = 0;
  CompressionLevelFast = 1;
  CompressionLevelDefault = 6;
  CompressionLevelBest = 9;

implementation

end.

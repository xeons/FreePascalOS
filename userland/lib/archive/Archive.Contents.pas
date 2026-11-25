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
  The contents of libarchive.so: reading zip, tar and tar.gz files,
  writing zip files, extracting into folders and browsing an archive
  like a folder. Compiling this unit compiles all of them.
}
unit Archive.Contents;

{$mode objfpc}

interface

uses
  Archive.Entries,
  Archive.Times,
  Archive.Progress,
  Archive.Cp437,
  Archive.FileSystem,
  Archive.ZipFormat,
  Archive.ZipEndRecord,
  Archive.ZipExtraFields,
  Archive.TarFormat,
  Archive.RewindingStreams,
  Archive.Readers,
  Archive.Detection,
  Archive.ZipReader,
  Archive.TarReader,
  Archive.ZipWriter,
  Archive.Extraction,
  Archive.Folders;

implementation

end.

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
  The contents of libcoreutils.so: helpers shared by the command line
  tools. Compiling this unit compiles all of them.
}
unit Util.Contents;

{$mode objfpc}

interface

uses
  Util.Messages,
  Util.Options,
  Util.Input,
  Util.Paths,
  Util.Sorting,
  Util.Sizes,
  Util.Directories,
  Util.FileTree,
  Util.DigestTool,
  Util.BaseEncoding,
  Util.Modes,
  Util.Dates,
  Util.Accounts,
  Util.Commands,
  Util.RegularExpressions,
  Util.LineEditor,
  Util.Globbing,
  Util.Passwords;

implementation

end.

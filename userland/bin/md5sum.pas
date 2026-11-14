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
  md5sum - compute and check MD5 (128-bit) message digests

  md5sum [-bt] [--tag] [-z] [FILE]...
  md5sum -c [--quiet] [--status] [--strict] [-w] [FILE]...

  See Util.DigestTool for the options.
}
program md5sum;

{$mode objfpc}

uses
  Crypto.Digests,
  Util.DigestTool;

begin
  RunDigestTool(DigestMd5);
end.

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
  basenc - encode or decode data as one of several encodings

  basenc [-di] [-w COLS] [FILE]

  See Util.BaseEncoding for the encodings and options.
}
program basenc;

{$mode objfpc}

uses
  Util.BaseEncoding;

begin
  RunBaseEncodingTool(EncodingBase64, True);
end.

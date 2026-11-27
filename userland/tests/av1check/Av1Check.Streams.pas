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
  The streams av1check decodes: small IVF files made with aomenc and
  the hashes of the frames aomdec gives for them
  (Av1Check.Streams.inc, written by tools/Av1Test/make-system-check.py).
}
unit Av1Check.Streams;

{$mode objfpc}

interface

type
  TCheckStream = record
    Name: string;
    Data: PByte;
    Size: Integer;
    Hashes: PQWord;
    FrameCount: Integer;
  end;

{$I Av1Check.Streams.inc}

implementation

end.

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
  Crypto.Random for the host build of TlsTest: the same interface as
  libcryptography's (which needs the FreePascalOS kernel), taking its
  bytes from the host's /dev/urandom.
}
unit Crypto.Random;

{$mode objfpc}

interface

procedure RandomBytes(Destination: PByte; Count: QWord);
function RandomQWord: QWord;
function RandomBelow(Bound: QWord): QWord;
function RandomIsStrong: Boolean;

implementation

procedure RandomBytes(Destination: PByte; Count: QWord);
var
  Source: File of Byte;
begin
  if Count = 0 then
    Exit;
  Assign(Source, '/dev/urandom');
  Reset(Source);
  BlockRead(Source, Destination^, Count);
  Close(Source);
end;

function RandomQWord: QWord;
begin
  RandomBytes(@Result, SizeOf(Result));
end;

function RandomBelow(Bound: QWord): QWord;
begin
  Result := RandomQWord mod Bound;
end;

function RandomIsStrong: Boolean;
begin
  Result := True;
end;

end.

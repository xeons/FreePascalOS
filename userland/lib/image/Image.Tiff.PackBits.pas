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
  PackBits (TIFF compression 32773), Apple's run-length coding: a
  header byte N, then N + 1 bytes as they are when N is 0 to 127, or
  the one next byte 1 - N times when N is -1 to -127; -128 is skipped.
  Runs may cross line boundaries, as libtiff allows.
}
unit Image.Tiff.PackBits;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

{ Unpacks Count bytes at Input into Output (Capacity bytes); gives how
  many were written. Data that ends early or runs past the room stops
  there. }
function UnpackBits(Input: PByte; Count: PtrInt; Output: PByte; Capacity: PtrInt): PtrInt;

implementation

function UnpackBits(Input: PByte; Count: PtrInt; Output: PByte; Capacity: PtrInt): PtrInt;
var
  Position: PtrInt;
  Header: LongInt;
  RunLength: PtrInt;
  Value: Byte;
begin
  Result := 0;
  Position := 0;
  while (Position < Count) and (Result < Capacity) do
  begin
    Header := ShortInt(Input[Position]);
    Inc(Position);
    if Header >= 0 then
    begin
      RunLength := Header + 1;
      if RunLength > Count - Position then
        RunLength := Count - Position;
      if RunLength > Capacity - Result then
        RunLength := Capacity - Result;
      Move(Input[Position], Output[Result], RunLength);
      Inc(Position, Header + 1);
      Inc(Result, RunLength);
    end
    else if Header <> -128 then
    begin
      if Position >= Count then
        Break;
      Value := Input[Position];
      Inc(Position);
      RunLength := 1 - Header;
      if RunLength > Capacity - Result then
        RunLength := Capacity - Result;
      FillChar(Output[Result], RunLength, Value);
      Inc(Result, RunLength);
    end;
  end;
end;

end.

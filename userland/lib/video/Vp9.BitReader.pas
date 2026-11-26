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
  Plain bits, most significant first: how a VP9 frame's uncompressed
  header is written. Reading past the end raises EVp9HeaderError.
}
unit Vp9.BitReader;

{$mode objfpc}
{$H+}
{$modeswitch advancedrecords}
{$pointermath on}

interface

uses
  SysUtils;

type
  EVp9HeaderError = class(Exception);

  TVp9BitReader = record
  private
    FData: PByte;
    FSize: PtrInt;
    FBitPosition: PtrInt;
  public
    procedure Init(Data: PByte; Size: PtrInt);
    function ReadBit: LongInt;
    function ReadLiteral(Bits: LongInt): LongInt;
    { Bits bits of magnitude, then a sign bit. }
    function ReadSignedLiteral(Bits: LongInt): LongInt;
    { Whole bytes taken so far (counting a partly read one). }
    function BytesRead: PtrInt;
  end;

implementation

procedure TVp9BitReader.Init(Data: PByte; Size: PtrInt);
begin
  FData := Data;
  FSize := Size;
  FBitPosition := 0;
end;

function TVp9BitReader.ReadBit: LongInt;
var
  ByteIndex: PtrInt;
begin
  ByteIndex := FBitPosition shr 3;
  if ByteIndex >= FSize then
    raise EVp9HeaderError.Create('VP9: truncated frame header');
  Result := (FData[ByteIndex] shr (7 - (FBitPosition and 7))) and 1;
  Inc(FBitPosition);
end;

function TVp9BitReader.ReadLiteral(Bits: LongInt): LongInt;
begin
  Result := 0;
  while Bits > 0 do
  begin
    Dec(Bits);
    Result := Result or (ReadBit shl Bits);
  end;
end;

function TVp9BitReader.ReadSignedLiteral(Bits: LongInt): LongInt;
begin
  Result := ReadLiteral(Bits);
  if ReadBit <> 0 then
    Result := -Result;
end;

function TVp9BitReader.BytesRead: PtrInt;
begin
  Result := (FBitPosition + 7) shr 3;
end;

end.

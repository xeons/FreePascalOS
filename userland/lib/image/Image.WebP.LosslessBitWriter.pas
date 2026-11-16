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
  The bit writer of VP8L: bits go into each byte from its least
  significant end, numbers least significant bit first (prefix codes
  are written already reversed, as deflate's).
}
unit Image.WebP.LosslessBitWriter;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TLosslessBitWriter = class
  private
    FData: TBytes;
    FSize: PtrInt;
    FAccumulator: QWord;
    FBitCount: LongInt;
    procedure FlushBytes;
  public
    constructor Create;
    { The low Count (at most 32) bits of Value. }
    procedure WriteBits(Value: LongWord; Count: LongInt);
    { Everything written, the last byte padded with zeros. }
    function ToBytes: TBytes;
  end;

implementation

constructor TLosslessBitWriter.Create;
begin
  inherited Create;
  SetLength(FData, 4096);
  FSize := 0;
  FAccumulator := 0;
  FBitCount := 0;
end;

procedure TLosslessBitWriter.FlushBytes;
begin
  while FBitCount >= 8 do
  begin
    if FSize >= Length(FData) then
      SetLength(FData, Length(FData) * 2);
    FData[FSize] := Byte(FAccumulator and $FF);
    Inc(FSize);
    FAccumulator := FAccumulator shr 8;
    Dec(FBitCount, 8);
  end;
end;

procedure TLosslessBitWriter.WriteBits(Value: LongWord; Count: LongInt);
begin
  if Count = 0 then
    Exit;
  FAccumulator := FAccumulator or ((QWord(Value) and ((QWord(1) shl Count) - 1)) shl FBitCount);
  Inc(FBitCount, Count);
  FlushBytes;
end;

function TLosslessBitWriter.ToBytes: TBytes;
begin
  if FBitCount > 0 then
  begin
    FBitCount := 8;
    FlushBytes;
  end;
  Result := Copy(FData, 0, FSize);
end;

end.

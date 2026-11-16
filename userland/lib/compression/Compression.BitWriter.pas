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
  The compressor's output: bits packed first bit first (deflate's
  order) into bytes that wait in a buffer until the caller takes them.
  The buffer grows as a block needs it and starts over once all of it
  has been taken, so it holds about one block at a time.
}
unit Compression.BitWriter;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

type
  TBitWriter = class
  private
    FBuffer: TBytes;
    FLength: SizeInt;
    FTaken: SizeInt;
    FBits: QWord;
    FBitCount: Integer;
    procedure EnsureRoom(Count: SizeInt);
    procedure FlushWholeBytes;
  public
    procedure Reset;
    { Count (up to 32) bits of Value, its lowest bit first. }
    procedure WriteBits(Value: LongWord; Count: Integer); inline;
    { Pads with zero bits to the next byte. }
    procedure AlignToByte;
    { Bytes as they are; the output must be at a byte boundary. }
    procedure WriteBytes(Data: PByte; Count: SizeInt);
    { Copies up to Capacity waiting bytes to Output; returns how many. }
    function Take(Output: PByte; Capacity: SizeInt): SizeInt;
    { Whole bytes waiting to be taken. }
    function Pending: SizeInt;
  end;

implementation

procedure TBitWriter.Reset;
begin
  FLength := 0;
  FTaken := 0;
  FBits := 0;
  FBitCount := 0;
end;

procedure TBitWriter.EnsureRoom(Count: SizeInt);
var
  NewSize: SizeInt;
begin
  if FLength + Count <= Length(FBuffer) then
    Exit;
  NewSize := 2 * Length(FBuffer);
  if NewSize < 65536 then
    NewSize := 65536;
  while NewSize < FLength + Count do
    NewSize := 2 * NewSize;
  SetLength(FBuffer, NewSize);
end;

procedure TBitWriter.WriteBits(Value: LongWord; Count: Integer);
begin
  FBits := FBits or (QWord(Value) shl FBitCount);
  Inc(FBitCount, Count);
  if FBitCount >= 32 then
  begin
    EnsureRoom(4);
    PLongWord(@FBuffer[FLength])^ := LongWord(FBits);
    Inc(FLength, 4);
    FBits := FBits shr 32;
    Dec(FBitCount, 32);
  end;
end;

procedure TBitWriter.FlushWholeBytes;
begin
  EnsureRoom(8);
  while FBitCount >= 8 do
  begin
    FBuffer[FLength] := Byte(FBits);
    Inc(FLength);
    FBits := FBits shr 8;
    Dec(FBitCount, 8);
  end;
end;

procedure TBitWriter.AlignToByte;
begin
  if (FBitCount and 7) <> 0 then
    Inc(FBitCount, 8 - (FBitCount and 7));
  FlushWholeBytes;
end;

procedure TBitWriter.WriteBytes(Data: PByte; Count: SizeInt);
begin
  FlushWholeBytes;
  if Count <= 0 then
    Exit;
  EnsureRoom(Count);
  Move(Data^, FBuffer[FLength], Count);
  Inc(FLength, Count);
end;

function TBitWriter.Take(Output: PByte; Capacity: SizeInt): SizeInt;
begin
  Result := FLength - FTaken;
  if Result > Capacity then
    Result := Capacity;
  if Result > 0 then
  begin
    Move(FBuffer[FTaken], Output^, Result);
    Inc(FTaken, Result);
  end;
  if FTaken = FLength then
  begin
    FTaken := 0;
    FLength := 0;
  end;
end;

function TBitWriter.Pending: SizeInt;
begin
  Result := FLength - FTaken;
end;

end.

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
  Building a file's bytes in memory: appended one number or run at a
  time (the buffer grows by doubling), numbers patched in later where a
  size is known only at the end, and the bytes taken when done.
}
unit Image.ByteWriters;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TImageByteWriter = class
  private
    FData: TBytes;
    FSize: PtrInt;
    procedure Reserve(Count: PtrInt);
  public
    constructor Create(InitialCapacity: PtrInt = 4096);
    procedure WriteByte(Value: Byte);
    procedure WriteWordLittle(Value: Word);
    procedure WriteLongLittle(Value: LongWord);
    procedure WriteWordBig(Value: Word);
    procedure WriteLongBig(Value: LongWord);
    procedure WriteBytes(const Bytes: TBytes);
    procedure WriteBuffer(const Buffer; Count: PtrInt);
    procedure WriteZeros(Count: PtrInt);
    procedure WriteText(const Text: string);
    { Overwrites the four bytes at Offset (already written). }
    procedure PatchLongLittle(Offset: PtrInt; Value: LongWord);
    procedure PatchWordLittle(Offset: PtrInt; Value: Word);
    { What was written. }
    function ToBytes: TBytes;
    property Size: PtrInt read FSize;
  end;

implementation

constructor TImageByteWriter.Create(InitialCapacity: PtrInt);
begin
  inherited Create;
  if InitialCapacity < 16 then
    InitialCapacity := 16;
  SetLength(FData, InitialCapacity);
  FSize := 0;
end;

procedure TImageByteWriter.Reserve(Count: PtrInt);
var
  Capacity: PtrInt;
begin
  Capacity := Length(FData);
  if FSize + Count <= Capacity then
    Exit;
  while Capacity < FSize + Count do
    Capacity := Capacity * 2;
  SetLength(FData, Capacity);
end;

procedure TImageByteWriter.WriteByte(Value: Byte);
begin
  Reserve(1);
  FData[FSize] := Value;
  Inc(FSize);
end;

procedure TImageByteWriter.WriteWordLittle(Value: Word);
begin
  WriteByte(Value and $FF);
  WriteByte(Value shr 8);
end;

procedure TImageByteWriter.WriteLongLittle(Value: LongWord);
begin
  WriteWordLittle(Value and $FFFF);
  WriteWordLittle(Value shr 16);
end;

procedure TImageByteWriter.WriteWordBig(Value: Word);
begin
  WriteByte(Value shr 8);
  WriteByte(Value and $FF);
end;

procedure TImageByteWriter.WriteLongBig(Value: LongWord);
begin
  WriteWordBig(Value shr 16);
  WriteWordBig(Value and $FFFF);
end;

procedure TImageByteWriter.WriteBytes(const Bytes: TBytes);
begin
  if Length(Bytes) > 0 then
    WriteBuffer(Bytes[0], Length(Bytes));
end;

procedure TImageByteWriter.WriteBuffer(const Buffer; Count: PtrInt);
begin
  if Count <= 0 then
    Exit;
  Reserve(Count);
  Move(Buffer, FData[FSize], Count);
  Inc(FSize, Count);
end;

procedure TImageByteWriter.WriteZeros(Count: PtrInt);
begin
  if Count <= 0 then
    Exit;
  Reserve(Count);
  FillChar(FData[FSize], Count, 0);
  Inc(FSize, Count);
end;

procedure TImageByteWriter.WriteText(const Text: string);
begin
  if Length(Text) > 0 then
    WriteBuffer(Text[1], Length(Text));
end;

procedure TImageByteWriter.PatchLongLittle(Offset: PtrInt; Value: LongWord);
begin
  PatchWordLittle(Offset, Value and $FFFF);
  PatchWordLittle(Offset + 2, Value shr 16);
end;

procedure TImageByteWriter.PatchWordLittle(Offset: PtrInt; Value: Word);
begin
  if (Offset < 0) or (Offset + 2 > FSize) then
    raise ERangeError.Create('patch outside what was written');
  FData[Offset] := Value and $FF;
  FData[Offset + 1] := Value shr 8;
end;

function TImageByteWriter.ToBytes: TBytes;
begin
  Result := Copy(FData, 0, FSize);
end;

end.

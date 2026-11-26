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
  A growing byte buffer for writing the binary format: bytes, LEB128
  numbers (unsigned and signed), names and length prefixed contents.
}
unit WasmText.Binary;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TBinaryWriter = class
  private
    FBytes: TBytes;
    FSize: Integer;
    procedure Reserve(Extra: Integer);
  public
    procedure WriteByte(Value: Byte);
    procedure WriteRaw(const Data; Count: Integer);
    procedure WriteRawString(const Data: AnsiString);
    procedure WriteUnsigned(Value: QWord);
    procedure WriteSigned(Value: Int64);
    { A name or byte string: its length, then its bytes. }
    procedure WriteName(const Data: AnsiString);
    { Another writer's contents, prefixed with their size. }
    procedure WriteSized(Other: TBinaryWriter);
    procedure WriteWriter(Other: TBinaryWriter);
    procedure Clear;
    function ToBytes: TBytes;
    property Size: Integer read FSize;
  end;

implementation

procedure TBinaryWriter.Reserve(Extra: Integer);
var
  Capacity: Integer;
begin
  if FSize + Extra > Length(FBytes) then
  begin
    Capacity := Length(FBytes) * 2 + 64;
    if Capacity < FSize + Extra then
      Capacity := FSize + Extra;
    SetLength(FBytes, Capacity);
  end;
end;

procedure TBinaryWriter.WriteByte(Value: Byte);
begin
  Reserve(1);
  FBytes[FSize] := Value;
  Inc(FSize);
end;

procedure TBinaryWriter.WriteRaw(const Data; Count: Integer);
begin
  if Count <= 0 then
    Exit;
  Reserve(Count);
  Move(Data, FBytes[FSize], Count);
  Inc(FSize, Count);
end;

procedure TBinaryWriter.WriteRawString(const Data: AnsiString);
begin
  if Data <> '' then
    WriteRaw(Data[1], Length(Data));
end;

procedure TBinaryWriter.WriteUnsigned(Value: QWord);
var
  Part: Byte;
begin
  repeat
    Part := Value and $7F;
    Value := Value shr 7;
    if Value <> 0 then
      Part := Part or $80;
    WriteByte(Part);
  until Value = 0;
end;

procedure TBinaryWriter.WriteSigned(Value: Int64);
var
  Part: Byte;
  Done: Boolean;
begin
  repeat
    Part := Byte(Value and $7F);
    Value := SarInt64(Value, 7);
    Done := ((Value = 0) and ((Part and $40) = 0)) or ((Value = -1) and ((Part and $40) <> 0));
    if not Done then
      Part := Part or $80;
    WriteByte(Part);
  until Done;
end;

procedure TBinaryWriter.WriteName(const Data: AnsiString);
begin
  WriteUnsigned(Length(Data));
  WriteRawString(Data);
end;

procedure TBinaryWriter.WriteSized(Other: TBinaryWriter);
begin
  WriteUnsigned(Other.Size);
  WriteWriter(Other);
end;

procedure TBinaryWriter.WriteWriter(Other: TBinaryWriter);
begin
  if Other.FSize > 0 then
    WriteRaw(Other.FBytes[0], Other.FSize);
end;

procedure TBinaryWriter.Clear;
begin
  FSize := 0;
end;

function TBinaryWriter.ToBytes: TBytes;
begin
  Result := Copy(FBytes, 0, FSize);
end;

end.

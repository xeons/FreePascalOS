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
  Reading and writing packets, frames and parameters in place: a reader
  over received bytes and a writer into a buffer of fixed size, both
  checking every length against what is left (nothing is allocated).
  A read that does not fit returns False and leaves the reader where it
  was; a write that does not fit sets Failed and writes nothing more.
}
unit Quic.Buffers;

{$mode objfpc}
{$modeswitch advancedrecords}
{$pointermath on}

interface

type
  TQuicReader = record
    Start: PByte;
    Position: PByte;
    Limit: PByte;
    procedure Initialize(Data: PByte; Length: PtrUInt);
    function Remaining: PtrUInt;
    function AtEnd: Boolean;
    { Bytes read so far. }
    function Consumed: PtrUInt;
    function ReadByte(out Value: Byte): Boolean;
    function ReadUInt16(out Value: Word): Boolean;
    function ReadUInt32(out Value: LongWord): Boolean;
    function ReadVariable(out Value: QWord): Boolean;
    { Count bytes in place (Data points into the buffer). }
    function ReadBytes(Count: PtrUInt; out Data: PByte): Boolean;
    function Skip(Count: PtrUInt): Boolean;
  end;

  TQuicWriter = record
    Start: PByte;
    Position: PByte;
    Limit: PByte;
    Failed: Boolean;
    procedure Initialize(Buffer: PByte; Capacity: PtrUInt);
    function Length: PtrUInt;
    function Room: PtrUInt;
    procedure WriteByte(Value: Byte);
    procedure WriteUInt16(Value: Word);
    procedure WriteUInt32(Value: LongWord);
    procedure WriteVariable(Value: QWord);
    procedure WriteBytes(Data: PByte; Count: PtrUInt);
    { Count zero bytes (PADDING frames). }
    procedure WriteZeros(Count: PtrUInt);
  end;

implementation

uses
  Quic.VariableIntegers;

procedure TQuicReader.Initialize(Data: PByte; Length: PtrUInt);
begin
  Start := Data;
  Position := Data;
  Limit := Data + Length;
end;

function TQuicReader.Remaining: PtrUInt;
begin
  Result := PtrUInt(Limit - Position);
end;

function TQuicReader.AtEnd: Boolean;
begin
  Result := Position >= Limit;
end;

function TQuicReader.Consumed: PtrUInt;
begin
  Result := PtrUInt(Position - Start);
end;

function TQuicReader.ReadByte(out Value: Byte): Boolean;
begin
  Value := 0;
  if Remaining < 1 then
    Exit(False);
  Value := Position^;
  Inc(Position);
  Result := True;
end;

function TQuicReader.ReadUInt16(out Value: Word): Boolean;
begin
  Value := 0;
  if Remaining < 2 then
    Exit(False);
  Value := (Word(Position[0]) shl 8) or Position[1];
  Position := Position + 2;
  Result := True;
end;

function TQuicReader.ReadUInt32(out Value: LongWord): Boolean;
begin
  Value := 0;
  if Remaining < 4 then
    Exit(False);
  Value := (LongWord(Position[0]) shl 24) or (LongWord(Position[1]) shl 16) or (LongWord(Position[2]) shl 8) or
    Position[3];
  Position := Position + 4;
  Result := True;
end;

function TQuicReader.ReadVariable(out Value: QWord): Boolean;
var
  Count: Integer;
begin
  Count := DecodeVariableInteger(Position, Remaining, Value);
  if Count = 0 then
    Exit(False);
  Position := Position + Count;
  Result := True;
end;

function TQuicReader.ReadBytes(Count: PtrUInt; out Data: PByte): Boolean;
begin
  Data := Position;
  if Remaining < Count then
    Exit(False);
  Position := Position + Count;
  Result := True;
end;

function TQuicReader.Skip(Count: PtrUInt): Boolean;
begin
  if Remaining < Count then
    Exit(False);
  Position := Position + Count;
  Result := True;
end;

procedure TQuicWriter.Initialize(Buffer: PByte; Capacity: PtrUInt);
begin
  Start := Buffer;
  Position := Buffer;
  Limit := Buffer + Capacity;
  Failed := False;
end;

function TQuicWriter.Length: PtrUInt;
begin
  Result := PtrUInt(Position - Start);
end;

function TQuicWriter.Room: PtrUInt;
begin
  if Failed then
    Exit(0);
  Result := PtrUInt(Limit - Position);
end;

procedure TQuicWriter.WriteByte(Value: Byte);
begin
  if Room < 1 then
  begin
    Failed := True;
    Exit;
  end;
  Position^ := Value;
  Inc(Position);
end;

procedure TQuicWriter.WriteUInt16(Value: Word);
begin
  if Room < 2 then
  begin
    Failed := True;
    Exit;
  end;
  Position[0] := Byte(Value shr 8);
  Position[1] := Byte(Value);
  Position := Position + 2;
end;

procedure TQuicWriter.WriteUInt32(Value: LongWord);
begin
  if Room < 4 then
  begin
    Failed := True;
    Exit;
  end;
  Position[0] := Byte(Value shr 24);
  Position[1] := Byte(Value shr 16);
  Position[2] := Byte(Value shr 8);
  Position[3] := Byte(Value);
  Position := Position + 4;
end;

procedure TQuicWriter.WriteVariable(Value: QWord);
var
  Count: Integer;
begin
  Count := VariableIntegerLength(Value);
  if (Value > MaximumVariableInteger) or (Room < PtrUInt(Count)) then
  begin
    Failed := True;
    Exit;
  end;
  EncodeVariableIntegerAs(Value, Count, Position);
  Position := Position + Count;
end;

procedure TQuicWriter.WriteBytes(Data: PByte; Count: PtrUInt);
begin
  if Room < Count then
  begin
    Failed := True;
    Exit;
  end;
  if Count > 0 then
    Move(Data^, Position^, Count);
  Position := Position + Count;
end;

procedure TQuicWriter.WriteZeros(Count: PtrUInt);
begin
  if Room < Count then
  begin
    Failed := True;
    Exit;
  end;
  if Count > 0 then
    FillChar(Position^, Count, 0);
  Position := Position + Count;
end;

end.

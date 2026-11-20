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
  A growable byte buffer for building frames and header blocks. Its
  storage is kept when it is cleared, so a buffer reused for every frame
  of a connection allocates only while it grows; it grows by doubling.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.ByteBuffers;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

type
  THttpByteBuffer = record
    Data: TBytes;
    Length: Integer;
  end;

procedure ClearBuffer(var Buffer: THttpByteBuffer);
procedure ReserveBuffer(var Buffer: THttpByteBuffer; Extra: Integer);
procedure AppendByte(var Buffer: THttpByteBuffer; Value: Byte);
procedure AppendBytes(var Buffer: THttpByteBuffer; Source: Pointer; Count: Integer);
procedure AppendText(var Buffer: THttpByteBuffer; const Text: string);
procedure AppendUInt16(var Buffer: THttpByteBuffer; Value: Word);
procedure AppendUInt24(var Buffer: THttpByteBuffer; Value: LongWord);
procedure AppendUInt32(var Buffer: THttpByteBuffer; Value: LongWord);
{ The bytes as a string (a copy). }
function BufferText(constref Buffer: THttpByteBuffer): string;
{ Drops Count bytes from the front, moving the rest down. }
procedure ConsumeBuffer(var Buffer: THttpByteBuffer; Count: Integer);

function ReadUInt16(Source: PByte): Word;
function ReadUInt24(Source: PByte): LongWord;
function ReadUInt32(Source: PByte): LongWord;

implementation

procedure ClearBuffer(var Buffer: THttpByteBuffer);
begin
  Buffer.Length := 0;
end;

procedure ReserveBuffer(var Buffer: THttpByteBuffer; Extra: Integer);
var
  Capacity: Integer;
begin
  if Buffer.Length + Extra <= System.Length(Buffer.Data) then
    Exit;
  Capacity := System.Length(Buffer.Data);
  if Capacity < 64 then
    Capacity := 64;
  while Capacity < Buffer.Length + Extra do
    Capacity := Capacity * 2;
  SetLength(Buffer.Data, Capacity);
end;

procedure AppendByte(var Buffer: THttpByteBuffer; Value: Byte);
begin
  ReserveBuffer(Buffer, 1);
  Buffer.Data[Buffer.Length] := Value;
  Inc(Buffer.Length);
end;

procedure AppendBytes(var Buffer: THttpByteBuffer; Source: Pointer; Count: Integer);
begin
  if Count <= 0 then
    Exit;
  ReserveBuffer(Buffer, Count);
  Move(Source^, Buffer.Data[Buffer.Length], Count);
  Inc(Buffer.Length, Count);
end;

procedure AppendText(var Buffer: THttpByteBuffer; const Text: string);
begin
  if Text <> '' then
    AppendBytes(Buffer, @Text[1], System.Length(Text));
end;

procedure AppendUInt16(var Buffer: THttpByteBuffer; Value: Word);
begin
  AppendByte(Buffer, Value shr 8);
  AppendByte(Buffer, Value and $FF);
end;

procedure AppendUInt24(var Buffer: THttpByteBuffer; Value: LongWord);
begin
  AppendByte(Buffer, (Value shr 16) and $FF);
  AppendByte(Buffer, (Value shr 8) and $FF);
  AppendByte(Buffer, Value and $FF);
end;

procedure AppendUInt32(var Buffer: THttpByteBuffer; Value: LongWord);
begin
  AppendByte(Buffer, Value shr 24);
  AppendByte(Buffer, (Value shr 16) and $FF);
  AppendByte(Buffer, (Value shr 8) and $FF);
  AppendByte(Buffer, Value and $FF);
end;

function BufferText(constref Buffer: THttpByteBuffer): string;
begin
  Result := '';
  SetLength(Result, Buffer.Length);
  if Buffer.Length > 0 then
    Move(Buffer.Data[0], Result[1], Buffer.Length);
end;

procedure ConsumeBuffer(var Buffer: THttpByteBuffer; Count: Integer);
begin
  if Count >= Buffer.Length then
  begin
    Buffer.Length := 0;
    Exit;
  end;
  Move(Buffer.Data[Count], Buffer.Data[0], Buffer.Length - Count);
  Dec(Buffer.Length, Count);
end;

function ReadUInt16(Source: PByte): Word;
begin
  Result := (Word(Source[0]) shl 8) or Source[1];
end;

function ReadUInt24(Source: PByte): LongWord;
begin
  Result := (LongWord(Source[0]) shl 16) or (LongWord(Source[1]) shl 8) or Source[2];
end;

function ReadUInt32(Source: PByte): LongWord;
begin
  Result := (LongWord(Source[0]) shl 24) or (LongWord(Source[1]) shl 16) or (LongWord(Source[2]) shl 8) or
    Source[3];
end;

end.

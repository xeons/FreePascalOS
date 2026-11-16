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
  Building and reading the big endian, length prefixed structures of
  TLS (RFC 8446 section 3).

  A builder grows as bytes are appended; a vector's length prefix is
  reserved first and filled in when the vector ends. Running out of
  memory marks the builder Failed, and later appends do nothing.

  A reader never goes past its end: every read checks the bytes that
  remain and fails (marking the reader Failed) rather than reading
  beyond them, so a length field in a message can never make the
  library read outside the message.
}
unit Tls.ByteBuffers;

{$mode objfpc}
{$pointermath on}

interface

type
  TTlsBuilder = record
    Data: PByte;
    Length: PtrUInt;
    Capacity: PtrUInt;
    Failed: Boolean;
  end;

  TTlsReader = record
    Position: PByte;
    Limit: PByte;
    Failed: Boolean;
  end;

  { Bytes somewhere else (inside a message, a certificate...). }
  TTlsByteRange = record
    Data: PByte;
    Length: PtrUInt;
  end;

procedure InitializeBuilder(out Builder: TTlsBuilder);
{ Wipes and frees the contents. }
procedure FreeBuilder(var Builder: TTlsBuilder);
procedure ClearBuilder(var Builder: TTlsBuilder);
procedure AppendByte(var Builder: TTlsBuilder; Value: Byte);
procedure AppendUInt16(var Builder: TTlsBuilder; Value: Word);
procedure AppendUInt24(var Builder: TTlsBuilder; Value: LongWord);
procedure AppendBytes(var Builder: TTlsBuilder; Bytes: Pointer; Count: PtrUInt);
{ Reserves a PrefixBytes long length (1, 2 or 3) and returns where the
  vector starts, for EndVector. }
function BeginVector(var Builder: TTlsBuilder; PrefixBytes: Integer): PtrUInt;
{ Fills in the length; fails the builder if it does not fit. }
procedure EndVector(var Builder: TTlsBuilder; Start: PtrUInt; PrefixBytes: Integer);
{ Drops the first Count bytes. }
procedure RemoveFromFront(var Builder: TTlsBuilder; Count: PtrUInt);

procedure InitializeReader(out Reader: TTlsReader; Data: PByte; Length: PtrUInt);
function ReaderRemaining(constref Reader: TTlsReader): PtrUInt;
function ReaderAtEnd(constref Reader: TTlsReader): Boolean;
function ReadUInt8(var Reader: TTlsReader; out Value: Byte): Boolean;
function ReadUInt16(var Reader: TTlsReader; out Value: Word): Boolean;
function ReadUInt24(var Reader: TTlsReader; out Value: LongWord): Boolean;
function ReadBytes(var Reader: TTlsReader; Count: PtrUInt; out Bytes: PByte): Boolean;
{ A vector with a PrefixBytes long length; Contents reads just it. }
function ReadVector(var Reader: TTlsReader; PrefixBytes: Integer; out Contents: TTlsReader): Boolean;
{ The same, as a byte range. }
function ReadVectorBytes(var Reader: TTlsReader; PrefixBytes: Integer; out Bytes: TTlsByteRange): Boolean;

function ByteRange(Data: PByte; Length: PtrUInt): TTlsByteRange;
function ByteRangesEqual(constref First, Second: TTlsByteRange): Boolean;

implementation

uses
  Crypto.Bits;

procedure InitializeBuilder(out Builder: TTlsBuilder);
begin
  Builder.Data := nil;
  Builder.Length := 0;
  Builder.Capacity := 0;
  Builder.Failed := False;
end;

procedure FreeBuilder(var Builder: TTlsBuilder);
begin
  if Builder.Data <> nil then
  begin
    WipeMemory(Builder.Data, Builder.Capacity);
    FreeMem(Builder.Data);
  end;
  InitializeBuilder(Builder);
end;

procedure ClearBuilder(var Builder: TTlsBuilder);
begin
  if Builder.Data <> nil then
    WipeMemory(Builder.Data, Builder.Length);
  Builder.Length := 0;
end;

{ Makes room for Count more bytes. }
function Reserve(var Builder: TTlsBuilder; Count: PtrUInt): Boolean;
var
  NewCapacity: PtrUInt;
  NewData: PByte;
begin
  if Builder.Failed then
    Exit(False);
  if Builder.Length + Count <= Builder.Capacity then
    Exit(True);
  NewCapacity := Builder.Capacity * 2;
  if NewCapacity < 256 then
    NewCapacity := 256;
  while NewCapacity < Builder.Length + Count do
    NewCapacity := NewCapacity * 2;
  NewData := GetMem(NewCapacity);
  if NewData = nil then
  begin
    Builder.Failed := True;
    Exit(False);
  end;
  if Builder.Data <> nil then
  begin
    Move(Builder.Data^, NewData^, Builder.Length);
    WipeMemory(Builder.Data, Builder.Capacity);
    FreeMem(Builder.Data);
  end;
  Builder.Data := NewData;
  Builder.Capacity := NewCapacity;
  Result := True;
end;

procedure AppendByte(var Builder: TTlsBuilder; Value: Byte);
begin
  if not Reserve(Builder, 1) then
    Exit;
  Builder.Data[Builder.Length] := Value;
  Inc(Builder.Length);
end;

procedure AppendUInt16(var Builder: TTlsBuilder; Value: Word);
begin
  AppendByte(Builder, Byte(Value shr 8));
  AppendByte(Builder, Byte(Value));
end;

procedure AppendUInt24(var Builder: TTlsBuilder; Value: LongWord);
begin
  AppendByte(Builder, Byte(Value shr 16));
  AppendByte(Builder, Byte(Value shr 8));
  AppendByte(Builder, Byte(Value));
end;

procedure AppendBytes(var Builder: TTlsBuilder; Bytes: Pointer; Count: PtrUInt);
begin
  if Count = 0 then
    Exit;
  if not Reserve(Builder, Count) then
    Exit;
  Move(Bytes^, Builder.Data[Builder.Length], Count);
  Builder.Length := Builder.Length + Count;
end;

function BeginVector(var Builder: TTlsBuilder; PrefixBytes: Integer): PtrUInt;
var
  Index: Integer;
begin
  for Index := 1 to PrefixBytes do
    AppendByte(Builder, 0);
  Result := Builder.Length;
end;

procedure EndVector(var Builder: TTlsBuilder; Start: PtrUInt; PrefixBytes: Integer);
var
  VectorLength: PtrUInt;
  Index: Integer;
begin
  if Builder.Failed then
    Exit;
  VectorLength := Builder.Length - Start;
  if VectorLength >= (PtrUInt(1) shl (8 * PrefixBytes)) then
  begin
    Builder.Failed := True;
    Exit;
  end;
  for Index := 1 to PrefixBytes do
    Builder.Data[Start - PtrUInt(Index)] := Byte(VectorLength shr (8 * (Index - 1)));
end;

procedure RemoveFromFront(var Builder: TTlsBuilder; Count: PtrUInt);
begin
  if Count >= Builder.Length then
  begin
    ClearBuilder(Builder);
    Exit;
  end;
  Move(Builder.Data[Count], Builder.Data[0], Builder.Length - Count);
  Builder.Length := Builder.Length - Count;
  WipeMemory(@Builder.Data[Builder.Length], Count);
end;

procedure InitializeReader(out Reader: TTlsReader; Data: PByte; Length: PtrUInt);
begin
  Reader.Position := Data;
  Reader.Limit := Data + Length;
  Reader.Failed := False;
end;

function ReaderRemaining(constref Reader: TTlsReader): PtrUInt;
begin
  Result := PtrUInt(Reader.Limit - Reader.Position);
end;

function ReaderAtEnd(constref Reader: TTlsReader): Boolean;
begin
  Result := Reader.Position = Reader.Limit;
end;

function ReadBytes(var Reader: TTlsReader; Count: PtrUInt; out Bytes: PByte): Boolean;
begin
  Bytes := nil;
  if Reader.Failed or (Count > ReaderRemaining(Reader)) then
  begin
    Reader.Failed := True;
    Exit(False);
  end;
  Bytes := Reader.Position;
  Reader.Position := Reader.Position + Count;
  Result := True;
end;

function ReadUInt8(var Reader: TTlsReader; out Value: Byte): Boolean;
var
  Bytes: PByte;
begin
  Value := 0;
  Result := ReadBytes(Reader, 1, Bytes);
  if Result then
    Value := Bytes[0];
end;

function ReadUInt16(var Reader: TTlsReader; out Value: Word): Boolean;
var
  Bytes: PByte;
begin
  Value := 0;
  Result := ReadBytes(Reader, 2, Bytes);
  if Result then
    Value := (Word(Bytes[0]) shl 8) or Bytes[1];
end;

function ReadUInt24(var Reader: TTlsReader; out Value: LongWord): Boolean;
var
  Bytes: PByte;
begin
  Value := 0;
  Result := ReadBytes(Reader, 3, Bytes);
  if Result then
    Value := (LongWord(Bytes[0]) shl 16) or (LongWord(Bytes[1]) shl 8) or Bytes[2];
end;

function ReadVector(var Reader: TTlsReader; PrefixBytes: Integer; out Contents: TTlsReader): Boolean;
var
  VectorLength: LongWord;
  Value8: Byte;
  Value16: Word;
  Bytes: PByte;
begin
  InitializeReader(Contents, nil, 0);
  Contents.Failed := True;
  case PrefixBytes of
    1:
      begin
        Result := ReadUInt8(Reader, Value8);
        VectorLength := Value8;
      end;
    2:
      begin
        Result := ReadUInt16(Reader, Value16);
        VectorLength := Value16;
      end;
  else
    Result := ReadUInt24(Reader, VectorLength);
  end;
  if not Result then
    Exit;
  Result := ReadBytes(Reader, VectorLength, Bytes);
  if Result then
    InitializeReader(Contents, Bytes, VectorLength);
end;

function ReadVectorBytes(var Reader: TTlsReader; PrefixBytes: Integer; out Bytes: TTlsByteRange): Boolean;
var
  Contents: TTlsReader;
begin
  Result := ReadVector(Reader, PrefixBytes, Contents);
  Bytes.Data := Contents.Position;
  Bytes.Length := 0;
  if Result then
    Bytes.Length := ReaderRemaining(Contents);
end;

function ByteRange(Data: PByte; Length: PtrUInt): TTlsByteRange;
begin
  Result.Data := Data;
  Result.Length := Length;
end;

function ByteRangesEqual(constref First, Second: TTlsByteRange): Boolean;
begin
  Result := (First.Length = Second.Length) and
    ((First.Length = 0) or (CompareByte(First.Data^, Second.Data^, First.Length) = 0));
end;

end.

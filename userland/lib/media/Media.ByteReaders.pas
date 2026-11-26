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
  Reading container structures: big and little-endian integers from a
  stream (TMediaReader, which raises EMediaError when the stream ends
  early) and from byte arrays.
}
unit Media.ByteReaders;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Media.Errors;

type
  TMediaReader = class
  private
    FStream: TStream;
    function GetPosition: Int64;
    procedure SetPosition(Value: Int64);
    function GetSize: Int64;
  public
    constructor Create(Stream: TStream);
    { Count bytes, or EMediaError if there are fewer. }
    procedure ReadExact(var Buffer; Count: Integer);
    function ReadBytes(Count: Integer): TBytes;
    { Up to Count bytes; how many were read. }
    function ReadUpTo(var Buffer; Count: Integer): Integer;
    function ReadU8: Byte;
    function ReadU16BE: Word;
    function ReadU24BE: LongWord;
    function ReadU32BE: LongWord;
    function ReadU64BE: QWord;
    function ReadU16LE: Word;
    function ReadU32LE: LongWord;
    function ReadU64LE: QWord;
    function ReadFourCC: string;
    procedure Skip(Count: Int64);
    function AtEnd: Boolean;
    property Position: Int64 read GetPosition write SetPosition;
    property Size: Int64 read GetSize;
    property Stream: TStream read FStream;
  end;

function BigEndian16(const Bytes: TBytes; Offset: Integer): Word;
function BigEndian24(const Bytes: TBytes; Offset: Integer): LongWord;
function BigEndian32(const Bytes: TBytes; Offset: Integer): LongWord;
function BigEndian64(const Bytes: TBytes; Offset: Integer): QWord;
function LittleEndian16(const Bytes: TBytes; Offset: Integer): Word;
function LittleEndian32(const Bytes: TBytes; Offset: Integer): LongWord;
function LittleEndian64(const Bytes: TBytes; Offset: Integer): QWord;
procedure PutLittleEndian16(var Bytes: TBytes; Offset: Integer; Value: Word);
procedure PutLittleEndian32(var Bytes: TBytes; Offset: Integer; Value: LongWord);
{ Count bytes of Bytes from Offset (fewer at the end). }
function SliceBytes(const Bytes: TBytes; Offset, Count: Integer): TBytes;
{ Four bytes at Offset as text. }
function FourCCAt(const Bytes: TBytes; Offset: Integer): string;

implementation

constructor TMediaReader.Create(Stream: TStream);
begin
  inherited Create;
  FStream := Stream;
end;

function TMediaReader.GetPosition: Int64;
begin
  Result := FStream.Position;
end;

procedure TMediaReader.SetPosition(Value: Int64);
begin
  FStream.Position := Value;
end;

function TMediaReader.GetSize: Int64;
begin
  Result := FStream.Size;
end;

procedure TMediaReader.ReadExact(var Buffer; Count: Integer);
begin
  if Count <= 0 then
    Exit;
  if FStream.Read(Buffer, Count) <> Count then
    MediaFail('unexpected end of file');
end;

function TMediaReader.ReadBytes(Count: Integer): TBytes;
begin
  Result := nil;
  if Count < 0 then
    MediaFail('negative length');
  if Count > FStream.Size - FStream.Position then
    MediaFail('unexpected end of file');
  SetLength(Result, Count);
  if Count > 0 then
    ReadExact(Result[0], Count);
end;

function TMediaReader.ReadUpTo(var Buffer; Count: Integer): Integer;
begin
  if Count <= 0 then
    Exit(0);
  Result := FStream.Read(Buffer, Count);
end;

function TMediaReader.ReadU8: Byte;
begin
  ReadExact(Result, 1);
end;

function TMediaReader.ReadU16BE: Word;
var
  Bytes: array[0..1] of Byte;
begin
  ReadExact(Bytes, 2);
  Result := (Bytes[0] shl 8) or Bytes[1];
end;

function TMediaReader.ReadU24BE: LongWord;
var
  Bytes: array[0..2] of Byte;
begin
  ReadExact(Bytes, 3);
  Result := (LongWord(Bytes[0]) shl 16) or (LongWord(Bytes[1]) shl 8) or Bytes[2];
end;

function TMediaReader.ReadU32BE: LongWord;
var
  Bytes: array[0..3] of Byte;
begin
  ReadExact(Bytes, 4);
  Result := (LongWord(Bytes[0]) shl 24) or (LongWord(Bytes[1]) shl 16) or (LongWord(Bytes[2]) shl 8) or Bytes[3];
end;

function TMediaReader.ReadU64BE: QWord;
var
  High32: QWord;
begin
  High32 := ReadU32BE;
  Result := (High32 shl 32) or ReadU32BE;
end;

function TMediaReader.ReadU16LE: Word;
var
  Bytes: array[0..1] of Byte;
begin
  ReadExact(Bytes, 2);
  Result := (Bytes[1] shl 8) or Bytes[0];
end;

function TMediaReader.ReadU32LE: LongWord;
var
  Bytes: array[0..3] of Byte;
begin
  ReadExact(Bytes, 4);
  Result := (LongWord(Bytes[3]) shl 24) or (LongWord(Bytes[2]) shl 16) or (LongWord(Bytes[1]) shl 8) or Bytes[0];
end;

function TMediaReader.ReadU64LE: QWord;
var
  Low32: QWord;
begin
  Low32 := ReadU32LE;
  Result := Low32 or (QWord(ReadU32LE) shl 32);
end;

function TMediaReader.ReadFourCC: string;
var
  Bytes: array[0..3] of Byte;
begin
  ReadExact(Bytes, 4);
  SetLength(Result, 4);
  Move(Bytes[0], Result[1], 4);
end;

procedure TMediaReader.Skip(Count: Int64);
begin
  if Count < 0 then
    MediaFail('negative skip');
  if FStream.Position + Count > FStream.Size then
    MediaFail('unexpected end of file');
  FStream.Position := FStream.Position + Count;
end;

function TMediaReader.AtEnd: Boolean;
begin
  Result := FStream.Position >= FStream.Size;
end;

procedure CheckRange(const Bytes: TBytes; Offset, Count: Integer);
begin
  if (Offset < 0) or (Offset + Count > Length(Bytes)) then
    MediaFail('structure is cut short');
end;

function BigEndian16(const Bytes: TBytes; Offset: Integer): Word;
begin
  CheckRange(Bytes, Offset, 2);
  Result := (Bytes[Offset] shl 8) or Bytes[Offset + 1];
end;

function BigEndian24(const Bytes: TBytes; Offset: Integer): LongWord;
begin
  CheckRange(Bytes, Offset, 3);
  Result := (LongWord(Bytes[Offset]) shl 16) or (LongWord(Bytes[Offset + 1]) shl 8) or Bytes[Offset + 2];
end;

function BigEndian32(const Bytes: TBytes; Offset: Integer): LongWord;
begin
  CheckRange(Bytes, Offset, 4);
  Result := (LongWord(Bytes[Offset]) shl 24) or (LongWord(Bytes[Offset + 1]) shl 16) or
    (LongWord(Bytes[Offset + 2]) shl 8) or Bytes[Offset + 3];
end;

function BigEndian64(const Bytes: TBytes; Offset: Integer): QWord;
begin
  Result := (QWord(BigEndian32(Bytes, Offset)) shl 32) or BigEndian32(Bytes, Offset + 4);
end;

function LittleEndian16(const Bytes: TBytes; Offset: Integer): Word;
begin
  CheckRange(Bytes, Offset, 2);
  Result := (Bytes[Offset + 1] shl 8) or Bytes[Offset];
end;

function LittleEndian32(const Bytes: TBytes; Offset: Integer): LongWord;
begin
  CheckRange(Bytes, Offset, 4);
  Result := (LongWord(Bytes[Offset + 3]) shl 24) or (LongWord(Bytes[Offset + 2]) shl 16) or
    (LongWord(Bytes[Offset + 1]) shl 8) or Bytes[Offset];
end;

function LittleEndian64(const Bytes: TBytes; Offset: Integer): QWord;
begin
  Result := LittleEndian32(Bytes, Offset) or (QWord(LittleEndian32(Bytes, Offset + 4)) shl 32);
end;

procedure PutLittleEndian16(var Bytes: TBytes; Offset: Integer; Value: Word);
begin
  CheckRange(Bytes, Offset, 2);
  Bytes[Offset] := Value and $FF;
  Bytes[Offset + 1] := Value shr 8;
end;

procedure PutLittleEndian32(var Bytes: TBytes; Offset: Integer; Value: LongWord);
begin
  CheckRange(Bytes, Offset, 4);
  Bytes[Offset] := Value and $FF;
  Bytes[Offset + 1] := (Value shr 8) and $FF;
  Bytes[Offset + 2] := (Value shr 16) and $FF;
  Bytes[Offset + 3] := Value shr 24;
end;

function SliceBytes(const Bytes: TBytes; Offset, Count: Integer): TBytes;
begin
  Result := nil;
  if Offset < 0 then
    Offset := 0;
  if Offset + Count > Length(Bytes) then
    Count := Length(Bytes) - Offset;
  if Count <= 0 then
    Exit;
  SetLength(Result, Count);
  Move(Bytes[Offset], Result[0], Count);
end;

function FourCCAt(const Bytes: TBytes; Offset: Integer): string;
begin
  CheckRange(Bytes, Offset, 4);
  SetLength(Result, 4);
  Move(Bytes[Offset], Result[1], 4);
end;

end.

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
  The wire format of the browser's messages between its processes:
  little-endian integers of fixed width, IEEE doubles, strings as their
  UTF-8 bytes after a 32-bit length, byte arrays the same way.

    Writer := TIpcWriter.Create;
    Writer.WriteString(Url);
    Writer.WriteLongInt(Width);
    Payload := Writer.Data;

    Reader := TIpcReader.Create(Payload);
    Url := Reader.ReadString;
    Width := Reader.ReadLongInt;

  A reader never reads past its data: a message cut short or a length
  that claims more than is left raises EIpcMalformed, which the
  receiving process treats as a broken peer (a renderer sending garbage
  is ended, never trusted).
}
unit WebIpc.Wire;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  EIpcMalformed = class(Exception);

  TIpcWriter = class
  private
    FBuffer: TBytes;
    FLength: Integer;
    procedure Reserve(Count: Integer);
  public
    procedure WriteRaw(Data: Pointer; Count: Integer);
    procedure WriteByte(Value: Byte);
    procedure WriteBoolean(Value: Boolean);
    procedure WriteWord(Value: Word);
    procedure WriteLongWord(Value: LongWord);
    procedure WriteLongInt(Value: LongInt);
    procedure WriteQWord(Value: QWord);
    procedure WriteInt64(Value: Int64);
    procedure WriteDouble(Value: Double);
    procedure WriteString(const Value: string);
    procedure WriteBytes(const Value: TBytes);
    { Count bytes at Data, length first (as WriteBytes). }
    procedure WriteBlock(Data: Pointer; Count: Integer);
    procedure WriteStrings(const Values: array of string);
    { What was written (a copy of exactly Length bytes). }
    function Data: TBytes;
    property Length: Integer read FLength;
  end;

  TIpcReader = class
  private
    FData: TBytes;
    FPosition: Integer;
    procedure Need(Count: Integer);
  public
    constructor Create(const AData: TBytes; Start: Integer = 0);
    procedure ReadRaw(Target: Pointer; Count: Integer);
    function ReadByte: Byte;
    function ReadBoolean: Boolean;
    function ReadWord: Word;
    function ReadLongWord: LongWord;
    function ReadLongInt: LongInt;
    function ReadQWord: QWord;
    function ReadInt64: Int64;
    function ReadDouble: Double;
    function ReadString: string;
    function ReadBytes: TBytes;
    function ReadStrings: TStringArray;
    function Remaining: Integer;
    property Position: Integer read FPosition;
  end;

{ The integers in the byte order on the wire, for headers written by hand. }
procedure StoreLongWord(Target: PByte; Value: LongWord);
function LoadLongWord(Source: PByte): LongWord;
procedure StoreWord(Target: PByte; Value: Word);
function LoadWord(Source: PByte): Word;

implementation

procedure StoreLongWord(Target: PByte; Value: LongWord);
begin
  Target[0] := Byte(Value);
  Target[1] := Byte(Value shr 8);
  Target[2] := Byte(Value shr 16);
  Target[3] := Byte(Value shr 24);
end;

function LoadLongWord(Source: PByte): LongWord;
begin
  Result := LongWord(Source[0]) or (LongWord(Source[1]) shl 8) or (LongWord(Source[2]) shl 16) or
    (LongWord(Source[3]) shl 24);
end;

procedure StoreWord(Target: PByte; Value: Word);
begin
  Target[0] := Byte(Value);
  Target[1] := Byte(Value shr 8);
end;

function LoadWord(Source: PByte): Word;
begin
  Result := Word(Source[0]) or (Word(Source[1]) shl 8);
end;

{ ---- TIpcWriter ---- }

procedure TIpcWriter.Reserve(Count: Integer);
var
  Capacity: Integer;
begin
  if FLength + Count <= System.Length(FBuffer) then
    Exit;
  Capacity := System.Length(FBuffer) * 2;
  if Capacity < 64 then
    Capacity := 64;
  while Capacity < FLength + Count do
    Capacity := Capacity * 2;
  SetLength(FBuffer, Capacity);
end;

procedure TIpcWriter.WriteRaw(Data: Pointer; Count: Integer);
begin
  if Count <= 0 then
    Exit;
  Reserve(Count);
  Move(Data^, FBuffer[FLength], Count);
  Inc(FLength, Count);
end;

procedure TIpcWriter.WriteByte(Value: Byte);
begin
  Reserve(1);
  FBuffer[FLength] := Value;
  Inc(FLength);
end;

procedure TIpcWriter.WriteBoolean(Value: Boolean);
begin
  if Value then
    WriteByte(1)
  else
    WriteByte(0);
end;

procedure TIpcWriter.WriteWord(Value: Word);
begin
  Reserve(2);
  StoreWord(@FBuffer[FLength], Value);
  Inc(FLength, 2);
end;

procedure TIpcWriter.WriteLongWord(Value: LongWord);
begin
  Reserve(4);
  StoreLongWord(@FBuffer[FLength], Value);
  Inc(FLength, 4);
end;

procedure TIpcWriter.WriteLongInt(Value: LongInt);
begin
  WriteLongWord(LongWord(Value));
end;

procedure TIpcWriter.WriteQWord(Value: QWord);
begin
  WriteLongWord(LongWord(Value and $FFFFFFFF));
  WriteLongWord(LongWord(Value shr 32));
end;

procedure TIpcWriter.WriteInt64(Value: Int64);
begin
  WriteQWord(QWord(Value));
end;

procedure TIpcWriter.WriteDouble(Value: Double);
var
  Bits: QWord;
begin
  Move(Value, Bits, SizeOf(Bits));
  WriteQWord(Bits);
end;

procedure TIpcWriter.WriteString(const Value: string);
begin
  WriteBlock(PChar(Value), System.Length(Value));
end;

procedure TIpcWriter.WriteBytes(const Value: TBytes);
begin
  if System.Length(Value) = 0 then
    WriteLongWord(0)
  else
    WriteBlock(@Value[0], System.Length(Value));
end;

procedure TIpcWriter.WriteBlock(Data: Pointer; Count: Integer);
begin
  if Count < 0 then
    Count := 0;
  WriteLongWord(LongWord(Count));
  WriteRaw(Data, Count);
end;

procedure TIpcWriter.WriteStrings(const Values: array of string);
var
  Index: Integer;
begin
  WriteLongWord(System.Length(Values));
  for Index := 0 to High(Values) do
    WriteString(Values[Index]);
end;

function TIpcWriter.Data: TBytes;
begin
  Result := nil;
  SetLength(Result, FLength);
  if FLength > 0 then
    Move(FBuffer[0], Result[0], FLength);
end;

{ ---- TIpcReader ---- }

constructor TIpcReader.Create(const AData: TBytes; Start: Integer);
begin
  inherited Create;
  FData := AData;
  FPosition := Start;
  if (Start < 0) or (Start > System.Length(FData)) then
    raise EIpcMalformed.Create('a message starts past its end');
end;

procedure TIpcReader.Need(Count: Integer);
begin
  if (Count < 0) or (Count > System.Length(FData) - FPosition) then
    raise EIpcMalformed.Create('a message is shorter than what it says');
end;

function TIpcReader.Remaining: Integer;
begin
  Result := System.Length(FData) - FPosition;
end;

procedure TIpcReader.ReadRaw(Target: Pointer; Count: Integer);
begin
  if Count <= 0 then
    Exit;
  Need(Count);
  Move(FData[FPosition], Target^, Count);
  Inc(FPosition, Count);
end;

function TIpcReader.ReadByte: Byte;
begin
  Need(1);
  Result := FData[FPosition];
  Inc(FPosition);
end;

function TIpcReader.ReadBoolean: Boolean;
begin
  Result := ReadByte <> 0;
end;

function TIpcReader.ReadWord: Word;
begin
  Need(2);
  Result := LoadWord(@FData[FPosition]);
  Inc(FPosition, 2);
end;

function TIpcReader.ReadLongWord: LongWord;
begin
  Need(4);
  Result := LoadLongWord(@FData[FPosition]);
  Inc(FPosition, 4);
end;

function TIpcReader.ReadLongInt: LongInt;
begin
  Result := LongInt(ReadLongWord);
end;

function TIpcReader.ReadQWord: QWord;
var
  Low: LongWord;
begin
  Low := ReadLongWord;
  Result := QWord(Low) or (QWord(ReadLongWord) shl 32);
end;

function TIpcReader.ReadInt64: Int64;
begin
  Result := Int64(ReadQWord);
end;

function TIpcReader.ReadDouble: Double;
var
  Bits: QWord;
begin
  Bits := ReadQWord;
  Move(Bits, Result, SizeOf(Result));
end;

function TIpcReader.ReadString: string;
var
  Count: LongWord;
begin
  Result := '';
  Count := ReadLongWord;
  if Count > LongWord(Remaining) then
    raise EIpcMalformed.Create('a string is longer than its message');
  SetLength(Result, Count);
  ReadRaw(PChar(Result), Count);
end;

function TIpcReader.ReadBytes: TBytes;
var
  Count: LongWord;
begin
  Result := nil;
  Count := ReadLongWord;
  if Count > LongWord(Remaining) then
    raise EIpcMalformed.Create('a byte array is longer than its message');
  SetLength(Result, Count);
  if Count > 0 then
    ReadRaw(@Result[0], Count);
end;

function TIpcReader.ReadStrings: TStringArray;
var
  Count, Index: LongWord;
begin
  Result := nil;
  Count := ReadLongWord;
  { Each string takes at least its length. }
  if Count > LongWord(Remaining) div 4 then
    raise EIpcMalformed.Create('a list is longer than its message');
  SetLength(Result, Count);
  Index := 0;
  while Index < Count do
  begin
    Result[Index] := ReadString;
    Inc(Index);
  end;
end;

end.

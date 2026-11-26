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
  The byte format of IndexedDB's requests and replies between the
  platform script (platform/81-indexeddb-backend.js) and the database
  service (Web.IndexedDb.Service), also what a content process sends
  the browser unchanged: little-endian fixed-width integers, doubles,
  byte strings with a 32-bit length. Names are opaque byte strings
  (the script sends UTF-16 code units, so names with lone surrogates
  stay distinct). A reader never reads past its data: input that does
  not parse raises EIdbMalformed.
}
unit Web.IndexedDb.Wire;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  { A reply's first byte. }
  IdbStatusOk = 0;
  IdbStatusConstraint = 1;
  IdbStatusQuotaExceeded = 2;
  IdbStatusNotFound = 3;
  IdbStatusVersion = 4;
  IdbStatusInvalidState = 5;
  IdbStatusUnknown = 6;
  IdbStatusData = 7;
  IdbStatusAbort = 8;
  IdbStatusSecurity = 9;

type
  EIdbMalformed = class(Exception);

  { A request that fails: the reply carries Status and the message. }
  EIdbFailure = class(Exception)
  public
    Status: Byte;
    constructor CreateStatus(AStatus: Byte; const AMessage: string);
  end;

  TIdbWriter = class
  private
    FData: TBytes;
    FLength: Integer;
    procedure Reserve(Count: Integer);
  public
    procedure WriteByte(Value: Byte);
    procedure WriteBoolean(Value: Boolean);
    procedure WriteLongWord(Value: LongWord);
    procedure WriteDouble(Value: Double);
    procedure WriteBytes(const Value: TBytes);
    procedure WriteRaw(const Value: RawByteString);
    function Data: TBytes;
  end;

  TIdbReader = class
  private
    FData: TBytes;
    FPosition: Integer;
    procedure Need(Count: Integer);
  public
    constructor Create(const AData: TBytes);
    function ReadByte: Byte;
    function ReadBoolean: Boolean;
    function ReadLongWord: LongWord;
    function ReadDouble: Double;
    function ReadBytes: TBytes;
    function ReadRaw: RawByteString;
    function AtEnd: Boolean;
  end;

implementation

const
  { The most one byte string may hold (a value or a request). }
  ItemLimit = 512 * 1024 * 1024;

constructor EIdbFailure.CreateStatus(AStatus: Byte; const AMessage: string);
begin
  inherited Create(AMessage);
  Status := AStatus;
end;

{ TIdbWriter }

procedure TIdbWriter.Reserve(Count: Integer);
var
  Capacity: Integer;
begin
  if FLength + Count <= Length(FData) then
    Exit;
  Capacity := Length(FData) * 2;
  if Capacity < 64 then
    Capacity := 64;
  while Capacity < FLength + Count do
    Capacity := Capacity * 2;
  SetLength(FData, Capacity);
end;

procedure TIdbWriter.WriteByte(Value: Byte);
begin
  Reserve(1);
  FData[FLength] := Value;
  Inc(FLength);
end;

procedure TIdbWriter.WriteBoolean(Value: Boolean);
begin
  WriteByte(Ord(Value));
end;

procedure TIdbWriter.WriteLongWord(Value: LongWord);
begin
  Reserve(4);
  FData[FLength] := Value and $FF;
  FData[FLength + 1] := (Value shr 8) and $FF;
  FData[FLength + 2] := (Value shr 16) and $FF;
  FData[FLength + 3] := (Value shr 24) and $FF;
  Inc(FLength, 4);
end;

procedure TIdbWriter.WriteDouble(Value: Double);
var
  Bits: QWord;
  Index: Integer;
begin
  Move(Value, Bits, 8);
  Reserve(8);
  for Index := 0 to 7 do
    FData[FLength + Index] := (Bits shr (8 * Index)) and $FF;
  Inc(FLength, 8);
end;

procedure TIdbWriter.WriteBytes(const Value: TBytes);
begin
  WriteLongWord(Length(Value));
  if Length(Value) = 0 then
    Exit;
  Reserve(Length(Value));
  Move(Value[0], FData[FLength], Length(Value));
  Inc(FLength, Length(Value));
end;

procedure TIdbWriter.WriteRaw(const Value: RawByteString);
begin
  WriteLongWord(Length(Value));
  if Length(Value) = 0 then
    Exit;
  Reserve(Length(Value));
  Move(Value[1], FData[FLength], Length(Value));
  Inc(FLength, Length(Value));
end;

function TIdbWriter.Data: TBytes;
begin
  Result := Copy(FData, 0, FLength);
end;

{ TIdbReader }

constructor TIdbReader.Create(const AData: TBytes);
begin
  inherited Create;
  FData := AData;
end;

procedure TIdbReader.Need(Count: Integer);
begin
  if (Count < 0) or (Count > Length(FData) - FPosition) then
    raise EIdbMalformed.Create('IndexedDB message cut short');
end;

function TIdbReader.ReadByte: Byte;
begin
  Need(1);
  Result := FData[FPosition];
  Inc(FPosition);
end;

function TIdbReader.ReadBoolean: Boolean;
begin
  Result := ReadByte <> 0;
end;

function TIdbReader.ReadLongWord: LongWord;
begin
  Need(4);
  Result := LongWord(FData[FPosition]) or (LongWord(FData[FPosition + 1]) shl 8) or
    (LongWord(FData[FPosition + 2]) shl 16) or (LongWord(FData[FPosition + 3]) shl 24);
  Inc(FPosition, 4);
end;

function TIdbReader.ReadDouble: Double;
var
  Bits: QWord;
  Index: Integer;
begin
  Need(8);
  Bits := 0;
  for Index := 7 downto 0 do
    Bits := (Bits shl 8) or FData[FPosition + Index];
  Inc(FPosition, 8);
  Move(Bits, Result, 8);
end;

function TIdbReader.ReadBytes: TBytes;
var
  Count: LongWord;
begin
  Result := nil;
  Count := ReadLongWord;
  if Count > ItemLimit then
    raise EIdbMalformed.Create('IndexedDB item too large');
  Need(Count);
  if Count = 0 then
    Exit;
  SetLength(Result, Count);
  Move(FData[FPosition], Result[0], Count);
  Inc(FPosition, Count);
end;

function TIdbReader.ReadRaw: RawByteString;
var
  Count: LongWord;
begin
  Result := '';
  Count := ReadLongWord;
  if Count > ItemLimit then
    raise EIdbMalformed.Create('IndexedDB item too large');
  Need(Count);
  if Count = 0 then
    Exit;
  SetLength(Result, Count);
  Move(FData[FPosition], Result[1], Count);
  Inc(FPosition, Count);
end;

function TIdbReader.AtEnd: Boolean;
begin
  Result := FPosition >= Length(FData);
end;

end.

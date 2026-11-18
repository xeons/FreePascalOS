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
  The data types of SSH messages (RFC 4251 section 5): byte, boolean,
  uint32, uint64, string, mpint and name-list.

  Byte strings are Pascal strings used as byte buffers (any byte, no
  code page conversion: every one is a plain `string`). A message is
  built by concatenating encodings:

    Payload := SshByte(MessageChannelEof) + SshUInt32(RemoteId);

  and read with a TSshReader, which raises ESshProtocolError when the
  message ends early or holds a value that is not allowed.
}
unit Ssh.Wire;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils;

type
  { The peer sent something that does not follow the protocol. }
  ESshProtocolError = class(Exception);

  TSshReader = record
  private
    FData: string;
    FPosition: Integer;
    procedure Need(Count: Integer);
  public
    procedure Start(const Data: string);
    function ReadByte: Byte;
    function ReadBoolean: Boolean;
    function ReadUInt32: LongWord;
    function ReadUInt64: QWord;
    function ReadString: string;
    { A non-negative mpint as its big endian magnitude, without leading
      zeros (empty for zero). }
    function ReadMpint: string;
    function ReadNameList: TStringArray;
    function Remaining: Integer;
    function AtEnd: Boolean;
    { The bytes not read yet. }
    function Rest: string;
  end;

function SshByte(Value: Byte): string;
function SshBoolean(Value: Boolean): string;
function SshUInt32(Value: LongWord): string;
function SshUInt64(Value: QWord): string;
function SshString(const Value: string): string;
{ An mpint from an unsigned big endian magnitude (leading zeros are
  dropped; a 0 byte goes in front when the top bit is set). }
function SshMpint(const Magnitude: string): string;
function SshNameList(const Names: array of string): string;

{ Big endian helpers for raw buffers. }
function ReadBigEndian32(const Data: string; Position: Integer): LongWord;
function BigEndian32Bytes(Value: LongWord): string;
{ The bytes of a raw buffer as a string and back. }
function BytesToString(Bytes: PByte; Count: Integer): string;
{ Splits a comma separated name-list. }
function SplitNameList(const Text: string): TStringArray;
function NameListContains(const Names: TStringArray; const Name: string): Boolean;
{ Overwrites a string's bytes (passwords, keys) before it is freed. }
procedure WipeString(var Value: string);

implementation

procedure TSshReader.Start(const Data: string);
begin
  FData := Data;
  FPosition := 1;
end;

procedure TSshReader.Need(Count: Integer);
begin
  if (Count < 0) or (FPosition + Count - 1 > Length(FData)) then
    raise ESshProtocolError.Create('message ends early');
end;

function TSshReader.ReadByte: Byte;
begin
  Need(1);
  Result := Ord(FData[FPosition]);
  Inc(FPosition);
end;

function TSshReader.ReadBoolean: Boolean;
begin
  Result := ReadByte <> 0;
end;

function TSshReader.ReadUInt32: LongWord;
begin
  Need(4);
  Result := ReadBigEndian32(FData, FPosition);
  Inc(FPosition, 4);
end;

function TSshReader.ReadUInt64: QWord;
var
  High, Low: LongWord;
begin
  High := ReadUInt32;
  Low := ReadUInt32;
  Result := (QWord(High) shl 32) or Low;
end;

function TSshReader.ReadString: string;
var
  Count: LongWord;
begin
  Count := ReadUInt32;
  if Count > LongWord(Length(FData)) then
    raise ESshProtocolError.Create('string longer than its message');
  Need(Integer(Count));
  Result := Copy(FData, FPosition, Integer(Count));
  Inc(FPosition, Integer(Count));
end;

function TSshReader.ReadMpint: string;
var
  FirstSignificant: Integer;
begin
  Result := ReadString;
  if (Result <> '') and (Ord(Result[1]) >= $80) then
    raise ESshProtocolError.Create('negative mpint');
  FirstSignificant := 1;
  while (FirstSignificant <= Length(Result)) and (Result[FirstSignificant] = #0) do
    Inc(FirstSignificant);
  Result := Copy(Result, FirstSignificant, MaxInt);
end;

function TSshReader.ReadNameList: TStringArray;
begin
  Result := SplitNameList(ReadString);
end;

function TSshReader.Remaining: Integer;
begin
  Result := Length(FData) - FPosition + 1;
end;

function TSshReader.AtEnd: Boolean;
begin
  Result := Remaining <= 0;
end;

function TSshReader.Rest: string;
begin
  Result := Copy(FData, FPosition, MaxInt);
end;

function SshByte(Value: Byte): string;
begin
  Result := Chr(Value);
end;

function SshBoolean(Value: Boolean): string;
begin
  if Value then
    Result := #1
  else
    Result := #0;
end;

function BigEndian32Bytes(Value: LongWord): string;
begin
  Result := '';
  SetLength(Result, 4);
  Result[1] := Chr((Value shr 24) and $FF);
  Result[2] := Chr((Value shr 16) and $FF);
  Result[3] := Chr((Value shr 8) and $FF);
  Result[4] := Chr(Value and $FF);
end;

function SshUInt32(Value: LongWord): string;
begin
  Result := BigEndian32Bytes(Value);
end;

function SshUInt64(Value: QWord): string;
begin
  Result := BigEndian32Bytes(LongWord(Value shr 32)) + BigEndian32Bytes(LongWord(Value and $FFFFFFFF));
end;

function SshString(const Value: string): string;
begin
  Result := BigEndian32Bytes(LongWord(Length(Value))) + Value;
end;

function SshMpint(const Magnitude: string): string;
var
  Start: Integer;
  Trimmed: string;
begin
  Start := 1;
  while (Start <= Length(Magnitude)) and (Magnitude[Start] = #0) do
    Inc(Start);
  Trimmed := Copy(Magnitude, Start, MaxInt);
  if (Trimmed <> '') and (Ord(Trimmed[1]) >= $80) then
    Trimmed := #0 + Trimmed;
  Result := SshString(Trimmed);
end;

function SshNameList(const Names: array of string): string;
var
  Text: string;
  Index: Integer;
begin
  Text := '';
  for Index := 0 to High(Names) do
  begin
    if Index > 0 then
      Text := Text + ',';
    Text := Text + Names[Index];
  end;
  Result := SshString(Text);
end;

function ReadBigEndian32(const Data: string; Position: Integer): LongWord;
begin
  Result := (LongWord(Ord(Data[Position])) shl 24) or (LongWord(Ord(Data[Position + 1])) shl 16) or
    (LongWord(Ord(Data[Position + 2])) shl 8) or LongWord(Ord(Data[Position + 3]));
end;

function BytesToString(Bytes: PByte; Count: Integer): string;
begin
  Result := '';
  SetLength(Result, Count);
  if Count > 0 then
    Move(Bytes^, Result[1], Count);
end;

function SplitNameList(const Text: string): TStringArray;
var
  Start, Index, Count: Integer;
begin
  Result := nil;
  if Text = '' then
    Exit;
  Count := 0;
  Start := 1;
  for Index := 1 to Length(Text) + 1 do
    if (Index > Length(Text)) or (Text[Index] = ',') then
    begin
      SetLength(Result, Count + 1);
      Result[Count] := Copy(Text, Start, Index - Start);
      Inc(Count);
      Start := Index + 1;
    end;
end;

function NameListContains(const Names: TStringArray; const Name: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Names) do
    if Names[Index] = Name then
      Exit(True);
  Result := False;
end;

procedure WipeString(var Value: string);
begin
  if Value <> '' then
  begin
    UniqueString(Value);
    FillChar(Value[1], Length(Value), 0);
  end;
  Value := '';
end;

end.

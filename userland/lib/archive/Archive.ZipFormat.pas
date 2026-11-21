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
  The zip format (PKWARE's APPNOTE): record signatures and sizes, the
  flags and extra field ids used here, and little-endian numbers read
  from and written to byte arrays.
}
unit Archive.ZipFormat;

{$mode objfpc}
{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils;

const
  LocalHeaderSignature = $04034B50;
  CentralHeaderSignature = $02014B50;
  EndOfCentralDirectorySignature = $06054B50;
  Zip64EndOfCentralDirectorySignature = $06064B50;
  Zip64EndLocatorSignature = $07064B50;
  DataDescriptorSignature = $08074B50;

  LocalHeaderSize = 30;
  CentralHeaderSize = 46;
  EndOfCentralDirectorySize = 22;
  Zip64EndOfCentralDirectorySize = 56;
  Zip64EndLocatorSize = 20;
  { The end record is followed by a comment of up to 65535 bytes. }
  MaximumCommentSize = 65535;

  { General purpose flags. }
  FlagEncrypted = $0001;
  FlagDataDescriptor = $0008;
  FlagStrongEncryption = $0040;
  FlagUtf8 = $0800;

  { Extra fields. }
  ExtraZip64 = $0001;
  ExtraExtendedTimestamp = $5455;
  ExtraUnicodePath = $7075;

  { Methods besides stored and deflated that are known by name. }
  MethodAesEncrypted = 99;

  { The system in the high byte of "version made by". }
  MadeByDos = 0;
  MadeByUnix = 3;

  { The DOS folder attribute in the external attributes. }
  DosFolderAttribute = $10;

  VersionDefault = 20;
  VersionZip64 = 45;

  Max16 = $FFFF;
  Max32 = QWord($FFFFFFFF);

function ReadWord(const Data: TBytes; Offset: SizeInt): Word;
function ReadLongWord(const Data: TBytes; Offset: SizeInt): LongWord;
function ReadQWord(const Data: TBytes; Offset: SizeInt): QWord;

type
  { Bytes put together for a header. }
  TByteBuilder = record
    Data: TBytes;
    Length: SizeInt;
    procedure Clear;
    procedure AddByte(Value: Byte);
    procedure AddWord(Value: Word);
    procedure AddLongWord(Value: LongWord);
    procedure AddQWord(Value: QWord);
    procedure AddText(const Text: string);
    procedure AddBytes(const Bytes: TBytes; Count: SizeInt);
    function Bytes: TBytes;
  end;

implementation

function ReadWord(const Data: TBytes; Offset: SizeInt): Word;
begin
  Result := Word(Data[Offset]) or (Word(Data[Offset + 1]) shl 8);
end;

function ReadLongWord(const Data: TBytes; Offset: SizeInt): LongWord;
begin
  Result := LongWord(ReadWord(Data, Offset)) or (LongWord(ReadWord(Data, Offset + 2)) shl 16);
end;

function ReadQWord(const Data: TBytes; Offset: SizeInt): QWord;
begin
  Result := QWord(ReadLongWord(Data, Offset)) or (QWord(ReadLongWord(Data, Offset + 4)) shl 32);
end;

procedure TByteBuilder.Clear;
begin
  Length := 0;
end;

procedure TByteBuilder.AddByte(Value: Byte);
begin
  if Length >= System.Length(Data) then
    SetLength(Data, 2 * Length + 64);
  Data[Length] := Value;
  Inc(Length);
end;

procedure TByteBuilder.AddWord(Value: Word);
begin
  AddByte(Value and $FF);
  AddByte(Value shr 8);
end;

procedure TByteBuilder.AddLongWord(Value: LongWord);
begin
  AddWord(Value and $FFFF);
  AddWord(Value shr 16);
end;

procedure TByteBuilder.AddQWord(Value: QWord);
begin
  AddLongWord(LongWord(Value and $FFFFFFFF));
  AddLongWord(LongWord(Value shr 32));
end;

procedure TByteBuilder.AddText(const Text: string);
var
  Index: Integer;
begin
  for Index := 1 to System.Length(Text) do
    AddByte(Ord(Text[Index]));
end;

procedure TByteBuilder.AddBytes(const Bytes: TBytes; Count: SizeInt);
var
  Index: SizeInt;
begin
  Index := 0;
  while Index < Count do
  begin
    AddByte(Bytes[Index]);
    Inc(Index);
  end;
end;

function TByteBuilder.Bytes: TBytes;
begin
  Result := Copy(Data, 0, Length);
end;

end.

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
  The extra fields of a zip central directory header that the reader
  uses: ZIP64 sizes and offset (0x0001), the extended timestamp
  (0x5455, Unix seconds) and Info-ZIP's Unicode path (0x7075).
}
unit Archive.ZipExtraFields;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TZipExtraInfo = record
    HasModificationTime: Boolean;
    ModificationTime: Int64;
    HasUnicodePath: Boolean;
    UnicodePath: string;
  end;

  { The central header's 32-bit values that the ZIP64 field replaces
    when they are all ones. }
  TZip64Values = record
    UncompressedSize: QWord;
    CompressedSize: QWord;
    LocalHeaderOffset: QWord;
  end;

{ Reads the extra fields from Extra[Offset .. Offset + Count - 1];
  RawName is the header's name, which a Unicode path must match the
  CRC-32 of. Fields that do not fit their length are passed over. }
procedure ReadExtraFields(const Extra: TBytes; Offset, Count: SizeInt; const RawName: string;
  var Values: TZip64Values; out Info: TZipExtraInfo);

implementation

uses
  Compression.Checksums,
  Archive.ZipFormat;

procedure ReadZip64Field(const Extra: TBytes; Offset, Count: SizeInt; var Values: TZip64Values);
var
  Position: SizeInt;

  procedure Replace(var Value: QWord);
  begin
    if (Value = Max32) and (Position + 8 <= Offset + Count) then
    begin
      Value := ReadQWord(Extra, Position);
      Inc(Position, 8);
    end;
  end;

begin
  Position := Offset;
  Replace(Values.UncompressedSize);
  Replace(Values.CompressedSize);
  Replace(Values.LocalHeaderOffset);
end;

procedure ReadTimestampField(const Extra: TBytes; Offset, Count: SizeInt; var Info: TZipExtraInfo);
begin
  if (Count >= 5) and ((Extra[Offset] and 1) <> 0) then
  begin
    Info.ModificationTime := LongInt(ReadLongWord(Extra, Offset + 1));
    Info.HasModificationTime := True;
  end;
end;

procedure ReadUnicodePathField(const Extra: TBytes; Offset, Count: SizeInt; const RawName: string;
  var Info: TZipExtraInfo);
var
  NameCrc: LongWord;
begin
  if (Count < 5) or (Extra[Offset] <> 1) then
    Exit;
  if RawName = '' then
    NameCrc := Crc32(Crc32Initial, nil, 0)
  else
    NameCrc := Crc32(Crc32Initial, PByte(@RawName[1]), Length(RawName));
  if NameCrc <> ReadLongWord(Extra, Offset + 1) then
    Exit;
  SetLength(Info.UnicodePath, Count - 5);
  if Count > 5 then
    Move(Extra[Offset + 5], Info.UnicodePath[1], Count - 5);
  Info.HasUnicodePath := True;
end;

procedure ReadExtraFields(const Extra: TBytes; Offset, Count: SizeInt; const RawName: string;
  var Values: TZip64Values; out Info: TZipExtraInfo);
var
  Position, FieldEnd: SizeInt;
  FieldId, FieldSize: Word;
begin
  Info := Default(TZipExtraInfo);
  Position := Offset;
  FieldEnd := Offset + Count;
  while Position + 4 <= FieldEnd do
  begin
    FieldId := ReadWord(Extra, Position);
    FieldSize := ReadWord(Extra, Position + 2);
    Inc(Position, 4);
    if Position + FieldSize > FieldEnd then
      Break;
    case FieldId of
      ExtraZip64: ReadZip64Field(Extra, Position, FieldSize, Values);
      ExtraExtendedTimestamp: ReadTimestampField(Extra, Position, FieldSize, Info);
      ExtraUnicodePath: ReadUnicodePathField(Extra, Position, FieldSize, RawName, Info);
    end;
    Inc(Position, FieldSize);
  end;
end;

end.

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
  The tar header (POSIX ustar, GNU and the old v7 layout): its fields,
  numbers in octal or GNU's base 256, the checksum, and pax extended
  header records ("LENGTH KEY=VALUE" lines).
}
unit Archive.TarFormat;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  TarBlockSize = 512;

  { Header field offsets and lengths. }
  TarNameOffset = 0;
  TarNameLength = 100;
  TarModeOffset = 100;
  TarSizeOffset = 124;
  TarModificationTimeOffset = 136;
  TarChecksumOffset = 148;
  TarTypeOffset = 156;
  TarLinkNameOffset = 157;
  TarLinkNameLength = 100;
  TarMagicOffset = 257;
  TarPrefixOffset = 345;
  TarPrefixLength = 155;

  { Type flags. }
  TarTypeRegular = '0';
  TarTypeRegularOld = #0;
  TarTypeHardLink = '1';
  TarTypeSymbolicLink = '2';
  TarTypeFolder = '5';
  TarTypeContiguous = '7';
  TarTypeGnuLongName = 'L';
  TarTypeGnuLongLink = 'K';
  TarTypePaxHeader = 'x';
  TarTypePaxGlobalHeader = 'g';

type
  TTarBlock = array[0..TarBlockSize - 1] of Byte;

  TTarMagic = (TarMagicNone, TarMagicUstar, TarMagicGnu);

  TPaxRecords = record
    Path: string;
    LinkPath: string;
    Size: QWord;
    ModificationTime: Int64;
    HasPath, HasLinkPath, HasSize, HasModificationTime: Boolean;
  end;

function BlockIsZero(const Block: TTarBlock): Boolean;
{ Whether the header's checksum (summed unsigned or signed) is right. }
function TarChecksumIsValid(const Block: TTarBlock): Boolean;
{ Whether the block looks like a tar header: "ustar" at 257, or a right
  checksum. }
function IsTarHeader(const Block: TTarBlock): Boolean;
function TarMagicOf(const Block: TTarBlock): TTarMagic;
{ A NUL-ended text field. }
function TarText(const Block: TTarBlock; Offset, Count: Integer): string;
{ A number in octal (spaces and NULs around it) or base 256 (the high
  bit of the first byte set). False if it is neither. }
function TarNumber(const Block: TTarBlock; Offset, Count: Integer; out Value: Int64): Boolean;
{ The member's name: ustar's prefix '/' name, or the name alone. }
function TarHeaderName(const Block: TTarBlock): string;
{ Bytes of padding after Size bytes of data to the next block. }
function TarPadding(Size: QWord): QWord;
{ Reads the records of a pax header into Records (keys it does not use
  are passed over). }
procedure ParsePaxRecords(const Data: string; var Records: TPaxRecords);

implementation

function BlockIsZero(const Block: TTarBlock): Boolean;
var
  Index: Integer;
begin
  Result := True;
  for Index := 0 to TarBlockSize - 1 do
    if Block[Index] <> 0 then
      Exit(False);
end;

function TarChecksumIsValid(const Block: TTarBlock): Boolean;
var
  Index: Integer;
  UnsignedSum, SignedSum, Stored: Int64;
begin
  UnsignedSum := 0;
  SignedSum := 0;
  for Index := 0 to TarBlockSize - 1 do
    if (Index >= TarChecksumOffset) and (Index < TarChecksumOffset + 8) then
    begin
      Inc(UnsignedSum, 32);
      Inc(SignedSum, 32);
    end
    else
    begin
      Inc(UnsignedSum, Block[Index]);
      Inc(SignedSum, ShortInt(Block[Index]));
    end;
  Result := TarNumber(Block, TarChecksumOffset, 8, Stored) and ((Stored = UnsignedSum) or (Stored = SignedSum));
end;

function TarMagicOf(const Block: TTarBlock): TTarMagic;
var
  Magic: string;
begin
  SetLength(Magic, 8);
  Move(Block[TarMagicOffset], Magic[1], 8);
  if Copy(Magic, 1, 6) = 'ustar'#0 then
    Result := TarMagicUstar
  else if Magic = 'ustar  '#0 then
    Result := TarMagicGnu
  else
    Result := TarMagicNone;
end;

function IsTarHeader(const Block: TTarBlock): Boolean;
begin
  if BlockIsZero(Block) then
    Exit(False);
  Result := TarChecksumIsValid(Block);
end;

function TarText(const Block: TTarBlock; Offset, Count: Integer): string;
var
  Length: Integer;
begin
  Length := 0;
  while (Length < Count) and (Block[Offset + Length] <> 0) do
    Inc(Length);
  SetLength(Result, Length);
  if Length > 0 then
    Move(Block[Offset], Result[1], Length);
end;

function TarNumber(const Block: TTarBlock; Offset, Count: Integer; out Value: Int64): Boolean;
var
  Index: Integer;
  Digit: Byte;
  SeenDigit: Boolean;
begin
  Value := 0;
  if (Block[Offset] and $80) <> 0 then
  begin
    { Base 256, big-endian; only positive values of up to 63 bits. }
    if (Block[Offset] and $40) <> 0 then
      Exit(False);
    for Index := Offset + 1 to Offset + Count - 1 do
    begin
      if Value > (High(Int64) shr 8) then
        Exit(False);
      Value := (Value shl 8) or Block[Index];
    end;
    Exit(True);
  end;
  Index := Offset;
  while (Index < Offset + Count) and (Block[Index] = Ord(' ')) do
    Inc(Index);
  SeenDigit := False;
  while Index < Offset + Count do
  begin
    Digit := Block[Index];
    if (Digit = 0) or (Digit = Ord(' ')) then
      Break;
    if (Digit < Ord('0')) or (Digit > Ord('7')) then
      Exit(False);
    if Value > (High(Int64) shr 3) then
      Exit(False);
    Value := (Value shl 3) or (Digit - Ord('0'));
    SeenDigit := True;
    Inc(Index);
  end;
  Result := SeenDigit or (Index < Offset + Count);
end;

function TarHeaderName(const Block: TTarBlock): string;
var
  Prefix: string;
begin
  Result := TarText(Block, TarNameOffset, TarNameLength);
  if TarMagicOf(Block) = TarMagicUstar then
  begin
    Prefix := TarText(Block, TarPrefixOffset, TarPrefixLength);
    if Prefix <> '' then
      Result := Prefix + '/' + Result;
  end;
end;

function TarPadding(Size: QWord): QWord;
begin
  Result := (TarBlockSize - (Size mod TarBlockSize)) mod TarBlockSize;
end;

{ Decimal seconds, maybe with a fraction (dropped) and a sign. }
function ParsePaxTime(const Text: string; out Value: Int64): Boolean;
var
  WholePart: string;
  DotPosition: Integer;
begin
  WholePart := Text;
  DotPosition := Pos('.', WholePart);
  if DotPosition > 0 then
    WholePart := Copy(WholePart, 1, DotPosition - 1);
  Result := TryStrToInt64(WholePart, Value);
  { -1.5 is a second and a half before 1970: round towards -infinity. }
  if Result and (DotPosition > 0) and (Text[1] = '-') and
    (StringReplace(Copy(Text, DotPosition + 1, Length(Text)), '0', '', [rfReplaceAll]) <> '') then
    Dec(Value);
end;

procedure ParsePaxRecords(const Data: string; var Records: TPaxRecords);
var
  Position, SpacePosition, EqualsPosition, RecordLength: Integer;
  Line, Key, Value: string;
  Number: Int64;
begin
  Position := 1;
  while Position <= Length(Data) do
  begin
    SpacePosition := Position;
    while (SpacePosition <= Length(Data)) and (Data[SpacePosition] in ['0'..'9']) do
      Inc(SpacePosition);
    if (SpacePosition > Length(Data)) or (Data[SpacePosition] <> ' ') then
      Exit;
    RecordLength := StrToIntDef(Copy(Data, Position, SpacePosition - Position), 0);
    if (RecordLength <= SpacePosition - Position + 1) or (Position + RecordLength - 1 > Length(Data)) then
      Exit;
    { "KEY=VALUE" without the final newline. }
    Line := Copy(Data, SpacePosition + 1, Position + RecordLength - SpacePosition - 2);
    Position := Position + RecordLength;
    EqualsPosition := Pos('=', Line);
    if EqualsPosition = 0 then
      Continue;
    Key := Copy(Line, 1, EqualsPosition - 1);
    Value := Copy(Line, EqualsPosition + 1, Length(Line));
    if Key = 'path' then
    begin
      Records.Path := Value;
      Records.HasPath := True;
    end
    else if Key = 'linkpath' then
    begin
      Records.LinkPath := Value;
      Records.HasLinkPath := True;
    end
    else if Key = 'size' then
    begin
      if TryStrToInt64(Value, Number) and (Number >= 0) then
      begin
        Records.Size := QWord(Number);
        Records.HasSize := True;
      end;
    end
    else if Key = 'mtime' then
    begin
      if ParsePaxTime(Value, Number) then
      begin
        Records.ModificationTime := Number;
        Records.HasModificationTime := True;
      end;
    end;
  end;
end;

end.

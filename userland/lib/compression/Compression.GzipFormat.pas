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
  The gzip wrapper (RFC 1952). A gzip file is one or more members, each

    a header: magic 1F 8B, method 8 (deflate), flags, modification time,
      extra flags, operating system; then, as the flags say, an extra
      field (a 16-bit length and that many bytes), the original file
      name and a comment (each ended by a zero byte), and the low 16
      bits of the header's CRC-32
    the deflate data
    a trailer: the CRC-32 and the length modulo 2^32 of the uncompressed
      data, least significant byte first

  The header is read a byte at a time (TGzipHeaderReader), so it may
  arrive in any number of pieces; names and comments are kept as the
  bytes they are (ISO 8859-1 by the standard).
}
unit Compression.GzipFormat;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Compression.Errors,
  Compression.Checksums;

const
  GzipFirstMagic = $1F;
  GzipSecondMagic = $8B;
  GzipTrailerSize = 8;
  GzipOperatingSystemUnknown = 255;

type
  TGzipHeader = record
    IsText: Boolean;
    { Seconds since 1970 (UTC), 0 if not known. }
    ModificationTime: LongWord;
    ExtraFlags: Byte;
    OperatingSystem: Byte;
    Extra: TBytes;
    HasExtra: Boolean;
    FileName: RawByteString;
    Comment: RawByteString;
    { Written with (or read with) a header CRC. }
    HasHeaderCrc: Boolean;
  end;

  TGzipHeaderProgress = (GzipHeaderIncomplete, GzipHeaderComplete, GzipHeaderInvalid);

  TGzipHeaderStage = (StageFixed, StageExtraLength, StageExtraData, StageFileName, StageComment, StageHeaderCrc,
    StageComplete, StageInvalid);

  TGzipHeaderReader = class
  private
    FBytes: TBytes;
    FCount: Integer;
    FStage: TGzipHeaderStage;
    FStageStart: Integer;
    FFlags: Byte;
    FExtraLength: Integer;
    FHeader: TGzipHeader;
    FError: TCompressionError;
    procedure Append(Value: Byte);
    procedure EnterNextStage;
    function Invalid(Error: TCompressionError): TGzipHeaderProgress;
    function FinishFixedPart: TGzipHeaderProgress;
    function CopyField(First: Integer; Count: Integer): RawByteString;
  public
    procedure Reset;
    { Takes the next byte of the header. }
    function Feed(Value: Byte): TGzipHeaderProgress;
    property Header: TGzipHeader read FHeader;
    property Error: TCompressionError read FError;
  end;

{ A header for Header's fields; ExtraFlags and OperatingSystem are
  written as given. }
function BuildGzipHeader(const Header: TGzipHeader): TBytes;
{ A header with no name and no time, for data compressed at Level. }
function DefaultGzipHeader(Level: Integer): TGzipHeader;

implementation

const
  DeflateMethod = 8;
  FixedPartSize = 10;
  { The longest name or comment taken; longer means a damaged header. }
  LongestTextField = 65536;

  FlagText = $01;
  FlagHeaderCrc = $02;
  FlagExtra = $04;
  FlagFileName = $08;
  FlagComment = $10;
  ReservedFlags = $E0;

procedure TGzipHeaderReader.Reset;
begin
  FCount := 0;
  FStage := StageFixed;
  FStageStart := 0;
  FFlags := 0;
  FExtraLength := 0;
  FError := CompressionErrorNone;
  FHeader := Default(TGzipHeader);
end;

procedure TGzipHeaderReader.Append(Value: Byte);
begin
  if FCount >= Length(FBytes) then
    SetLength(FBytes, 2 * FCount + 64);
  FBytes[FCount] := Value;
  Inc(FCount);
end;

function TGzipHeaderReader.Invalid(Error: TCompressionError): TGzipHeaderProgress;
begin
  FError := Error;
  FStage := StageInvalid;
  Result := GzipHeaderInvalid;
end;

function TGzipHeaderReader.CopyField(First: Integer; Count: Integer): RawByteString;
begin
  Result := '';
  SetLength(Result, Count);
  if Count > 0 then
    Move(FBytes[First], Result[1], Count);
end;

{ Moves on to the next field the flags ask for. }
procedure TGzipHeaderReader.EnterNextStage;
begin
  FStageStart := FCount;
  repeat
    case FStage of
      StageFixed: FStage := StageExtraLength;
      StageExtraLength: FStage := StageExtraData;
      StageExtraData: FStage := StageFileName;
      StageFileName: FStage := StageComment;
      StageComment: FStage := StageHeaderCrc;
      StageHeaderCrc: FStage := StageComplete;
    end;
    case FStage of
      StageExtraLength, StageExtraData:
        if (FFlags and FlagExtra) <> 0 then
          Exit;
      StageFileName:
        if (FFlags and FlagFileName) <> 0 then
          Exit;
      StageComment:
        if (FFlags and FlagComment) <> 0 then
          Exit;
      StageHeaderCrc:
        if (FFlags and FlagHeaderCrc) <> 0 then
          Exit;
    else
      Exit;
    end;
  until False;
end;

function TGzipHeaderReader.FinishFixedPart: TGzipHeaderProgress;
begin
  if (FBytes[0] <> GzipFirstMagic) or (FBytes[1] <> GzipSecondMagic) then
  begin
    Result := Invalid(CompressionErrorInvalidGzipHeader);
    Exit;
  end;
  if FBytes[2] <> DeflateMethod then
  begin
    Result := Invalid(CompressionErrorUnsupportedMethod);
    Exit;
  end;
  FFlags := FBytes[3];
  if (FFlags and ReservedFlags) <> 0 then
  begin
    Result := Invalid(CompressionErrorInvalidGzipHeader);
    Exit;
  end;
  FHeader.IsText := (FFlags and FlagText) <> 0;
  FHeader.ModificationTime := LongWord(FBytes[4]) or (LongWord(FBytes[5]) shl 8) or (LongWord(FBytes[6]) shl 16) or
    (LongWord(FBytes[7]) shl 24);
  FHeader.ExtraFlags := FBytes[8];
  FHeader.OperatingSystem := FBytes[9];
  FHeader.HasExtra := (FFlags and FlagExtra) <> 0;
  FHeader.HasHeaderCrc := (FFlags and FlagHeaderCrc) <> 0;
  Result := GzipHeaderIncomplete;
end;

function TGzipHeaderReader.Feed(Value: Byte): TGzipHeaderProgress;
var
  ExpectedCrc: Word;
begin
  if FStage = StageComplete then
  begin
    Result := GzipHeaderComplete;
    Exit;
  end;
  if FStage = StageInvalid then
  begin
    Result := GzipHeaderInvalid;
    Exit;
  end;
  Append(Value);
  Result := GzipHeaderIncomplete;
  case FStage of
    StageFixed:
      if ((FCount = 1) and (Value <> GzipFirstMagic)) or ((FCount = 2) and (Value <> GzipSecondMagic)) then
      begin
        Result := Invalid(CompressionErrorInvalidGzipHeader);
        Exit;
      end
      else if FCount = FixedPartSize then
      begin
        Result := FinishFixedPart;
        if Result = GzipHeaderInvalid then
          Exit;
        EnterNextStage;
      end;
    StageExtraLength:
      if FCount - FStageStart = 2 then
      begin
        FExtraLength := FBytes[FStageStart] or (Integer(FBytes[FStageStart + 1]) shl 8);
        EnterNextStage;
        if FExtraLength = 0 then
          EnterNextStage;
      end;
    StageExtraData:
      if FCount - FStageStart = FExtraLength then
      begin
        SetLength(FHeader.Extra, FExtraLength);
        Move(FBytes[FStageStart], FHeader.Extra[0], FExtraLength);
        EnterNextStage;
      end;
    StageFileName, StageComment:
      if Value = 0 then
      begin
        if FStage = StageFileName then
          FHeader.FileName := CopyField(FStageStart, FCount - FStageStart - 1)
        else
          FHeader.Comment := CopyField(FStageStart, FCount - FStageStart - 1);
        EnterNextStage;
      end
      else if FCount - FStageStart > LongestTextField then
      begin
        Result := Invalid(CompressionErrorInvalidGzipHeader);
        Exit;
      end;
    StageHeaderCrc:
      if FCount - FStageStart = 2 then
      begin
        ExpectedCrc := Word(Crc32(Crc32Initial, @FBytes[0], FStageStart) and $FFFF);
        if (FBytes[FStageStart] or (Word(FBytes[FStageStart + 1]) shl 8)) <> ExpectedCrc then
        begin
          Result := Invalid(CompressionErrorHeaderCrcMismatch);
          Exit;
        end;
        EnterNextStage;
      end;
  end;
  if FStage = StageComplete then
    Result := GzipHeaderComplete;
end;

procedure AppendByte(var Bytes: TBytes; Value: Byte);
begin
  SetLength(Bytes, Length(Bytes) + 1);
  Bytes[High(Bytes)] := Value;
end;

procedure AppendText(var Bytes: TBytes; const Text: RawByteString);
var
  Index: Integer;
begin
  for Index := 1 to Length(Text) do
  begin
    if Text[Index] = #0 then
      Break;
    AppendByte(Bytes, Ord(Text[Index]));
  end;
  AppendByte(Bytes, 0);
end;

function BuildGzipHeader(const Header: TGzipHeader): TBytes;
var
  Flags: Byte;
  ExtraLength: Integer;
  Index: Integer;
  HeaderCrc: LongWord;
begin
  Result := nil;
  Flags := 0;
  if Header.IsText then
    Flags := Flags or FlagText;
  if Header.HasExtra then
    Flags := Flags or FlagExtra;
  if Header.FileName <> '' then
    Flags := Flags or FlagFileName;
  if Header.Comment <> '' then
    Flags := Flags or FlagComment;
  if Header.HasHeaderCrc then
    Flags := Flags or FlagHeaderCrc;
  AppendByte(Result, GzipFirstMagic);
  AppendByte(Result, GzipSecondMagic);
  AppendByte(Result, DeflateMethod);
  AppendByte(Result, Flags);
  AppendByte(Result, Header.ModificationTime and $FF);
  AppendByte(Result, (Header.ModificationTime shr 8) and $FF);
  AppendByte(Result, (Header.ModificationTime shr 16) and $FF);
  AppendByte(Result, Header.ModificationTime shr 24);
  AppendByte(Result, Header.ExtraFlags);
  AppendByte(Result, Header.OperatingSystem);
  if Header.HasExtra then
  begin
    ExtraLength := Length(Header.Extra);
    if ExtraLength > $FFFF then
      ExtraLength := $FFFF;
    AppendByte(Result, ExtraLength and $FF);
    AppendByte(Result, ExtraLength shr 8);
    for Index := 0 to ExtraLength - 1 do
      AppendByte(Result, Header.Extra[Index]);
  end;
  if Header.FileName <> '' then
    AppendText(Result, Header.FileName);
  if Header.Comment <> '' then
    AppendText(Result, Header.Comment);
  if Header.HasHeaderCrc then
  begin
    HeaderCrc := Crc32(Crc32Initial, @Result[0], Length(Result));
    AppendByte(Result, HeaderCrc and $FF);
    AppendByte(Result, (HeaderCrc shr 8) and $FF);
  end;
end;

function DefaultGzipHeader(Level: Integer): TGzipHeader;
begin
  Result := Default(TGzipHeader);
  if Level >= 9 then
    Result.ExtraFlags := 2
  else if Level = 1 then
    Result.ExtraFlags := 4;
  Result.OperatingSystem := GzipOperatingSystemUnknown;
end;

end.

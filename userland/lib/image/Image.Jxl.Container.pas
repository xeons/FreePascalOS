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
  JPEG XL files (ISO/IEC 18181-2): a bare codestream ($FF $0A ...) or
  an ISO base media file format container: a signature box ('JXL '),
  'ftyp', then boxes, each a 32-bit big-endian size (1: a 64-bit size
  follows; 0: to the end of the file) and a four letter type. The
  codestream is one 'jxlc' box or 'jxlp' boxes (each starting with a
  32-bit index whose top bit marks the last part) put together.
  Metadata boxes are noted by type: 'Exif', 'xml ', 'jumb', 'jbrd'
  (what rebuilds the JPEG file the image came from), and 'brob' (a
  Brotli compressed box, named after the type it holds); 'jxll' (the
  level) and 'jxli' (a frame index) are passed over.
}
unit Image.Jxl.Container;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.ByteReaders;

const
  JxlCodestreamSignature: array[0..1] of Byte = ($FF, $0A);
  JxlContainerSignature: array[0..11] of Byte = (0, 0, 0, $0C, Ord('J'), Ord('X'), Ord('L'), Ord(' '), $0D, $0A,
    $87, $0A);

type
  TJxlFileContents = record
    Codestream: TBytes;
    IsContainer: Boolean;
    { The metadata boxes seen, by type ('Exif', 'xml'...), in order. }
    BoxNames: array of string;
    Exif: TBytes;
  end;

{ True when Data starts like a JPEG XL file. }
function IsJxlFile(const Data: TBytes): Boolean;
{ The codestream and metadata of a file. }
function ReadJxlFileContents(const Data: TBytes): TJxlFileContents;

implementation

function IsJxlFile(const Data: TBytes): Boolean;
begin
  Result := BytesStartWith(Data, JxlCodestreamSignature) or BytesStartWith(Data, JxlContainerSignature);
end;

function LoadBigEndian32(const Data: TBytes; Offset: PtrInt): LongWord;
begin
  Result := (LongWord(Data[Offset]) shl 24) or (LongWord(Data[Offset + 1]) shl 16) or
    (LongWord(Data[Offset + 2]) shl 8) or LongWord(Data[Offset + 3]);
end;

function BoxTypeName(const Data: TBytes; Offset: PtrInt): string;
var
  Index: LongInt;
begin
  SetLength(Result, 4);
  for Index := 0 to 3 do
    Result[Index + 1] := Chr(Data[Offset + Index]);
end;

procedure AppendBytes(var Target: TBytes; const Source: TBytes; Start, Count: PtrInt);
var
  OldLength: PtrInt;
begin
  if Count <= 0 then
    Exit;
  OldLength := Length(Target);
  SetLength(Target, OldLength + Count);
  Move(Source[Start], Target[OldLength], Count);
end;

procedure AddBoxName(var Contents: TJxlFileContents; const Name: string);
begin
  SetLength(Contents.BoxNames, Length(Contents.BoxNames) + 1);
  Contents.BoxNames[High(Contents.BoxNames)] := TrimRight(Name);
end;

function ReadJxlFileContents(const Data: TBytes): TJxlFileContents;
var
  Position: PtrInt;
  BoxStart: PtrInt;
  BoxSize: QWord;
  HeaderSize: PtrInt;
  BoxType: string;
  ContentStart: PtrInt;
  ContentSize: PtrInt;
  SawCodestreamBox: Boolean;
  LastPartSeen: Boolean;
  PartIndex: LongWord;
  ExpectedPart: LongWord;
begin
  Result := Default(TJxlFileContents);
  if BytesStartWith(Data, JxlCodestreamSignature) then
  begin
    Result.Codestream := Data;
    Exit;
  end;
  if not BytesStartWith(Data, JxlContainerSignature) then
    RaiseImageError(ImageErrorUnknownFormat, 'not JPEG XL');
  Result.IsContainer := True;
  Position := Length(JxlContainerSignature);
  SawCodestreamBox := False;
  LastPartSeen := False;
  ExpectedPart := 0;
  while Position < Length(Data) do
  begin
    BoxStart := Position;
    if Length(Data) - BoxStart < 8 then
      RaiseImageError(ImageErrorTruncated, 'JPEG XL box header');
    BoxSize := LoadBigEndian32(Data, BoxStart);
    BoxType := BoxTypeName(Data, BoxStart + 4);
    HeaderSize := 8;
    if BoxSize = 1 then
    begin
      if Length(Data) - BoxStart < 16 then
        RaiseImageError(ImageErrorTruncated, 'JPEG XL box header');
      BoxSize := (QWord(LoadBigEndian32(Data, BoxStart + 8)) shl 32) or LoadBigEndian32(Data, BoxStart + 12);
      HeaderSize := 16;
    end
    else if BoxSize = 0 then
      BoxSize := QWord(Length(Data) - BoxStart);
    if BoxSize < QWord(HeaderSize) then
      RaiseImageError(ImageErrorMalformed, 'JPEG XL box size');
    ContentStart := BoxStart + HeaderSize;
    if BoxSize > QWord(Length(Data) - BoxStart) then
    begin
      { A box cut short: what is there of a codestream is still used
        (the decoder then says where it ends), the rest is ignored. }
      BoxSize := QWord(Length(Data) - BoxStart);
    end;
    ContentSize := PtrInt(BoxSize) - HeaderSize;
    if BoxType = 'jxlc' then
    begin
      if SawCodestreamBox then
        RaiseImageError(ImageErrorMalformed, 'JPEG XL: more than one codestream box');
      SawCodestreamBox := True;
      AppendBytes(Result.Codestream, Data, ContentStart, ContentSize);
    end
    else if BoxType = 'jxlp' then
    begin
      if (SawCodestreamBox and (Length(Result.Codestream) > 0) and (ExpectedPart = 0)) or LastPartSeen then
        RaiseImageError(ImageErrorMalformed, 'JPEG XL: codestream boxes mixed');
      if ContentSize < 4 then
        RaiseImageError(ImageErrorTruncated, 'JPEG XL partial codestream box');
      PartIndex := LoadBigEndian32(Data, ContentStart);
      if (PartIndex and $7FFFFFFF) <> ExpectedPart then
        RaiseImageError(ImageErrorMalformed, 'JPEG XL: partial codestream boxes out of order');
      Inc(ExpectedPart);
      LastPartSeen := (PartIndex and $80000000) <> 0;
      SawCodestreamBox := True;
      AppendBytes(Result.Codestream, Data, ContentStart + 4, ContentSize - 4);
    end
    else if BoxType = 'brob' then
    begin
      if ContentSize >= 4 then
        AddBoxName(Result, BoxTypeName(Data, ContentStart) + ' (Brotli)');
    end
    else if BoxType = 'Exif' then
    begin
      AddBoxName(Result, BoxType);
      Result.Exif := Copy(Data, ContentStart, ContentSize);
    end
    else if (BoxType = 'xml ') or (BoxType = 'jumb') or (BoxType = 'jbrd') then
      AddBoxName(Result, BoxType);
    Position := BoxStart + PtrInt(BoxSize);
  end;
  if not SawCodestreamBox then
    RaiseImageError(ImageErrorTruncated, 'JPEG XL container without a codestream');
end;

end.

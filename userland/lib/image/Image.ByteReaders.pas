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
  Reading a file's bytes in memory, checked: every read that would go
  past the end raises EImageError (ImageErrorTruncated) instead, so a
  decoder never reads outside the data however its headers lie.
  Numbers little-endian (BMP, ICO, GIF) or big-endian (JPEG).
}
unit Image.ByteReaders;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors;

type
  TImageByteReader = class
  private
    FData: TBytes;
    FPosition: PtrInt;
    function GetSize: PtrInt;
    function GetRemaining: PtrInt;
  public
    constructor Create(const Data: TBytes);
    { Raises ImageErrorTruncated unless Count more bytes are there. }
    procedure Need(Count: PtrInt);
    function HasBytes(Count: PtrInt): Boolean;
    function ReadByte: Byte;
    function ReadWordLittle: Word;
    function ReadLongLittle: LongWord;
    function ReadSignedLongLittle: LongInt;
    function ReadWordBig: Word;
    function ReadLongBig: LongWord;
    function ReadBytes(Count: PtrInt): TBytes;
    procedure Skip(Count: PtrInt);
    { Moves to Offset from the start; past the end is truncation. }
    procedure Seek(Offset: PtrInt);
    function PeekByte(Offset: PtrInt): LongInt;
    property Data: TBytes read FData;
    property Position: PtrInt read FPosition;
    property Size: PtrInt read GetSize;
    property Remaining: PtrInt read GetRemaining;
  end;

{ Bytes Start to Start + Count - 1 of Data, checked. }
function SliceBytes(const Data: TBytes; Start, Count: PtrInt): TBytes;
{ The little-endian numbers at Offset, or 0 past the end. }
function PeekWordLittle(const Data: TBytes; Offset: PtrInt): LongWord;
function PeekLongLittle(const Data: TBytes; Offset: PtrInt): LongWord;
{ True when Data starts with Signature (at Offset). }
function BytesStartWith(const Data: TBytes; const Signature: array of Byte; Offset: PtrInt = 0): Boolean;

implementation

constructor TImageByteReader.Create(const Data: TBytes);
begin
  inherited Create;
  FData := Data;
  FPosition := 0;
end;

function TImageByteReader.GetSize: PtrInt;
begin
  Result := Length(FData);
end;

function TImageByteReader.GetRemaining: PtrInt;
begin
  Result := Length(FData) - FPosition;
end;

function TImageByteReader.HasBytes(Count: PtrInt): Boolean;
begin
  Result := (Count >= 0) and (Count <= Length(FData) - FPosition);
end;

procedure TImageByteReader.Need(Count: PtrInt);
begin
  if not HasBytes(Count) then
    RaiseImageError(ImageErrorTruncated, '');
end;

function TImageByteReader.ReadByte: Byte;
begin
  Need(1);
  Result := FData[FPosition];
  Inc(FPosition);
end;

function TImageByteReader.ReadWordLittle: Word;
begin
  Need(2);
  Result := FData[FPosition] or (Word(FData[FPosition + 1]) shl 8);
  Inc(FPosition, 2);
end;

function TImageByteReader.ReadLongLittle: LongWord;
begin
  Need(4);
  Result := FData[FPosition] or (LongWord(FData[FPosition + 1]) shl 8) or
    (LongWord(FData[FPosition + 2]) shl 16) or (LongWord(FData[FPosition + 3]) shl 24);
  Inc(FPosition, 4);
end;

function TImageByteReader.ReadSignedLongLittle: LongInt;
begin
  Result := LongInt(ReadLongLittle);
end;

function TImageByteReader.ReadWordBig: Word;
begin
  Need(2);
  Result := (Word(FData[FPosition]) shl 8) or FData[FPosition + 1];
  Inc(FPosition, 2);
end;

function TImageByteReader.ReadLongBig: LongWord;
begin
  Need(4);
  Result := (LongWord(FData[FPosition]) shl 24) or (LongWord(FData[FPosition + 1]) shl 16) or
    (LongWord(FData[FPosition + 2]) shl 8) or FData[FPosition + 3];
  Inc(FPosition, 4);
end;

function TImageByteReader.ReadBytes(Count: PtrInt): TBytes;
begin
  Need(Count);
  Result := Copy(FData, FPosition, Count);
  Inc(FPosition, Count);
end;

procedure TImageByteReader.Skip(Count: PtrInt);
begin
  Need(Count);
  Inc(FPosition, Count);
end;

procedure TImageByteReader.Seek(Offset: PtrInt);
begin
  if (Offset < 0) or (Offset > Length(FData)) then
    RaiseImageError(ImageErrorTruncated, '');
  FPosition := Offset;
end;

function TImageByteReader.PeekByte(Offset: PtrInt): LongInt;
begin
  if (Offset < 0) or (FPosition + Offset >= Length(FData)) then
    Exit(-1);
  Result := FData[FPosition + Offset];
end;

function SliceBytes(const Data: TBytes; Start, Count: PtrInt): TBytes;
begin
  if (Start < 0) or (Count < 0) or (Start > Length(Data)) or (Count > Length(Data) - Start) then
    RaiseImageError(ImageErrorTruncated, '');
  Result := Copy(Data, Start, Count);
end;

function PeekWordLittle(const Data: TBytes; Offset: PtrInt): LongWord;
begin
  if (Offset < 0) or (Offset + 2 > Length(Data)) then
    Exit(0);
  Result := Data[Offset] or (LongWord(Data[Offset + 1]) shl 8);
end;

function PeekLongLittle(const Data: TBytes; Offset: PtrInt): LongWord;
begin
  if (Offset < 0) or (Offset + 4 > Length(Data)) then
    Exit(0);
  Result := Data[Offset] or (LongWord(Data[Offset + 1]) shl 8) or (LongWord(Data[Offset + 2]) shl 16) or
    (LongWord(Data[Offset + 3]) shl 24);
end;

function BytesStartWith(const Data: TBytes; const Signature: array of Byte; Offset: PtrInt): Boolean;
var
  Index: PtrInt;
begin
  if (Offset < 0) or (Offset + Length(Signature) > Length(Data)) then
    Exit(False);
  for Index := 0 to High(Signature) do
    if Data[Offset + Index] <> Signature[Index] then
      Exit(False);
  Result := True;
end;

end.

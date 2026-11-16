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
  EXIF in a JPEG's APP1 segment: "Exif" and two zero bytes, then a TIFF
  structure (a header saying "II" for little-endian or "MM" for
  big-endian, and the offset of the first directory). Only the first
  directory's Orientation (tag $0112, a SHORT from 1 to 8) is read.
  Every offset is checked against the segment; anything that does not
  fit gives no orientation (0) rather than an error, since EXIF is
  optional.

  ReadTiffOrientation reads the same from a bare TIFF structure, as a
  PNG's eXIf chunk holds it.
}
unit Image.Jpeg.Exif;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

{ The orientation (1 to 8) in the APP1 segment's payload of Count bytes
  at Start in Data, or 0. }
function ReadExifOrientation(const Data: TBytes; Start, Count: PtrInt): LongInt;
{ The orientation (1 to 8) in the TIFF structure of Count bytes at
  Start in Data, or 0. }
function ReadTiffOrientation(const Data: TBytes; Start, Count: PtrInt): LongInt;

implementation

const
  OrientationTag = $0112;
  ShortType = 3;

type
  TTiffView = record
    Data: TBytes;
    Start: PtrInt;
    Count: PtrInt;
    BigEndian: Boolean;
  end;

function ViewWord(constref View: TTiffView; Offset: PtrInt; out Value: LongWord): Boolean;
var
  First: LongWord;
  Second: LongWord;
begin
  Value := 0;
  if (Offset < 0) or (Offset + 2 > View.Count) then
    Exit(False);
  First := View.Data[View.Start + Offset];
  Second := View.Data[View.Start + Offset + 1];
  if View.BigEndian then
    Value := (First shl 8) or Second
  else
    Value := (Second shl 8) or First;
  Result := True;
end;

function ViewLong(constref View: TTiffView; Offset: PtrInt; out Value: LongWord): Boolean;
var
  FirstHalf: LongWord;
  SecondHalf: LongWord;
begin
  Value := 0;
  if not ViewWord(View, Offset, FirstHalf) or not ViewWord(View, Offset + 2, SecondHalf) then
    Exit(False);
  if View.BigEndian then
    Value := (FirstHalf shl 16) or SecondHalf
  else
    Value := (SecondHalf shl 16) or FirstHalf;
  Result := True;
end;

function ReadTiffOrientation(const Data: TBytes; Start, Count: PtrInt): LongInt;
var
  View: TTiffView;
  DirectoryOffset: LongWord;
  EntryCount: LongWord;
  Entry: LongWord;
  EntryOffset: PtrInt;
  Tag: LongWord;
  FieldType: LongWord;
  Value: LongWord;
begin
  Result := 0;
  if (Start < 0) or (Count < 8) or (Start + Count > Length(Data)) then
    Exit;
  View.Data := Data;
  View.Start := Start;
  View.Count := Count;
  if (Data[View.Start] = Ord('I')) and (Data[View.Start + 1] = Ord('I')) then
    View.BigEndian := False
  else if (Data[View.Start] = Ord('M')) and (Data[View.Start + 1] = Ord('M')) then
    View.BigEndian := True
  else
    Exit;
  if not ViewLong(View, 4, DirectoryOffset) or (DirectoryOffset > LongWord(View.Count)) then
    Exit;
  if not ViewWord(View, DirectoryOffset, EntryCount) then
    Exit;
  Entry := 0;
  while Entry < EntryCount do
  begin
    EntryOffset := PtrInt(DirectoryOffset) + 2 + PtrInt(Entry) * 12;
    if not ViewWord(View, EntryOffset, Tag) or not ViewWord(View, EntryOffset + 2, FieldType) then
      Exit;
    if (Tag = OrientationTag) and (FieldType = ShortType) then
    begin
      if ViewWord(View, EntryOffset + 8, Value) and (Value >= 1) and (Value <= 8) then
        Result := Value;
      Exit;
    end;
    Inc(Entry);
  end;
end;

function ReadExifOrientation(const Data: TBytes; Start, Count: PtrInt): LongInt;
begin
  Result := 0;
  if (Start < 0) or (Count < 14) or (Start + Count > Length(Data)) then
    Exit;
  if (Data[Start] <> Ord('E')) or (Data[Start + 1] <> Ord('x')) or (Data[Start + 2] <> Ord('i')) or
    (Data[Start + 3] <> Ord('f')) or (Data[Start + 4] <> 0) or (Data[Start + 5] <> 0) then
    Exit;
  Result := ReadTiffOrientation(Data, Start + 6, Count - 6);
end;

end.

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
  Finding a zip file's central directory: the end of central directory
  record, searched for backwards over the comment that may follow it,
  and the ZIP64 end record its locator points to when the counts or
  offsets do not fit the old one.
}
unit Archive.ZipEndRecord;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils;

type
  TZipEnd = record
    EntryCount: QWord;
    DirectorySize: QWord;
    DirectoryOffset: QWord;
    { Where the end of central directory record starts. }
    EndRecordPosition: Int64;
    { Where the ZIP64 end record starts (-1 without one). }
    Zip64RecordPosition: Int64;
    IsZip64: Boolean;
  end;

{ Finds and reads the end records; False if there is no end of central
  directory record (or the ZIP64 one it needs is not where its locator
  says). }
function FindZipEnd(Stream: TStream; out ZipEnd: TZipEnd): Boolean;

implementation

uses
  Archive.ZipFormat;

function ReadAt(Stream: TStream; Position: Int64; Count: SizeInt): TBytes;
begin
  Result := nil;
  SetLength(Result, Count);
  Stream.Position := Position;
  if (Count > 0) and (Stream.Read(Result[0], Count) <> Count) then
    SetLength(Result, 0);
end;

{ The position of the last end of central directory record whose
  comment reaches exactly to the end of the file (else the last one at
  all), or -1. }
function SearchEndRecord(Stream: TStream): Int64;
var
  FileSize, TailStart: Int64;
  Tail: TBytes;
  Index: SizeInt;
  CommentLength: Word;
begin
  Result := -1;
  FileSize := Stream.Size;
  if FileSize < EndOfCentralDirectorySize then
    Exit;
  TailStart := FileSize - EndOfCentralDirectorySize - MaximumCommentSize;
  if TailStart < 0 then
    TailStart := 0;
  Tail := ReadAt(Stream, TailStart, FileSize - TailStart);
  if Length(Tail) = 0 then
    Exit;
  Index := Length(Tail) - EndOfCentralDirectorySize;
  while Index >= 0 do
  begin
    if ReadLongWord(Tail, Index) = EndOfCentralDirectorySignature then
    begin
      CommentLength := ReadWord(Tail, Index + 20);
      if Result < 0 then
        Result := TailStart + Index;
      if Index + EndOfCentralDirectorySize + CommentLength = Length(Tail) then
        Exit(TailStart + Index);
    end;
    Dec(Index);
  end;
end;

function ReadZip64End(Stream: TStream; var ZipEnd: TZipEnd): Boolean;
var
  Locator, Zip64Record: TBytes;
  RecordPosition: Int64;
begin
  Result := False;
  if ZipEnd.EndRecordPosition < Zip64EndLocatorSize then
    Exit;
  Locator := ReadAt(Stream, ZipEnd.EndRecordPosition - Zip64EndLocatorSize, Zip64EndLocatorSize);
  if (Length(Locator) = 0) or (ReadLongWord(Locator, 0) <> Zip64EndLocatorSignature) then
    Exit;
  RecordPosition := Int64(ReadQWord(Locator, 8));
  if (RecordPosition < 0) or (RecordPosition + Zip64EndOfCentralDirectorySize > Stream.Size) then
    Exit;
  Zip64Record := ReadAt(Stream, RecordPosition, Zip64EndOfCentralDirectorySize);
  if (Length(Zip64Record) = 0) or (ReadLongWord(Zip64Record, 0) <> Zip64EndOfCentralDirectorySignature) then
    Exit;
  ZipEnd.EntryCount := ReadQWord(Zip64Record, 32);
  ZipEnd.DirectorySize := ReadQWord(Zip64Record, 40);
  ZipEnd.DirectoryOffset := ReadQWord(Zip64Record, 48);
  ZipEnd.Zip64RecordPosition := RecordPosition;
  ZipEnd.IsZip64 := True;
  Result := True;
end;

function FindZipEnd(Stream: TStream; out ZipEnd: TZipEnd): Boolean;
var
  EndRecord: TBytes;
  NeedsZip64: Boolean;
begin
  ZipEnd := Default(TZipEnd);
  ZipEnd.Zip64RecordPosition := -1;
  ZipEnd.EndRecordPosition := SearchEndRecord(Stream);
  if ZipEnd.EndRecordPosition < 0 then
    Exit(False);
  EndRecord := ReadAt(Stream, ZipEnd.EndRecordPosition, EndOfCentralDirectorySize);
  if Length(EndRecord) = 0 then
    Exit(False);
  ZipEnd.EntryCount := ReadWord(EndRecord, 10);
  ZipEnd.DirectorySize := ReadLongWord(EndRecord, 12);
  ZipEnd.DirectoryOffset := ReadLongWord(EndRecord, 16);
  NeedsZip64 := (ZipEnd.EntryCount = Max16) or (ZipEnd.DirectorySize = Max32) or (ZipEnd.DirectoryOffset = Max32);
  { A locator is used whenever it is there, as other readers do. }
  if ReadZip64End(Stream, ZipEnd) then
    Exit(True);
  Result := not NeedsZip64 or (ZipEnd.EntryCount = Max16) and (ZipEnd.DirectorySize < Max32) and
    (ZipEnd.DirectoryOffset < Max32);
end;

end.

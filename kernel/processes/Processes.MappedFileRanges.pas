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
  The arithmetic of mapped files (Processes.MappedFiles): which pages a
  change of a file touches, which bytes of a page it touches, how much
  of a page writing it back writes, and which pages of a mapping a
  range of a mapped file covers.

  Kept free of kernel units so the host test (tools/MappedFileTest)
  checks it.
}
unit Processes.MappedFileRanges;

{$mode objfpc}

interface

const
  MappedPageBytes = 4096;
  { A change's Length reaching to the end of the file (a resize; the
    value of FileSystem.Files.FileChangeToEnd). }
  ChangeReachesEnd = High(QWord);

{ The pages [FirstPage, EndPage) of a file of PageCount pages that a
  change of Length bytes at Offset touches. False if it touches none. }
function ChangedPageSpan(Offset, Length, PageCount: QWord; out FirstPage, EndPage: QWord): Boolean;

{ The bytes [Start, Finish) inside page PageIndex (offsets from the
  page's start) that such a change touches; Start = Finish if none. }
procedure ChangedBytesInPage(PageIndex, Offset, Length: QWord; out Start, Finish: QWord);

{ The bytes of page PageIndex that lie before FileSize: what writing it
  back writes (0 for a page past the end). }
function BytesBeforeEnd(PageIndex, FileSize: QWord): QWord;

{ For a region of RegionPages pages mapping the file from page
  RegionFirstPage on: the pages of the file [FirstPage, EndPage) that
  lie in it, as [OverlapFirst, OverlapEnd). False if none do. }
function MappedOverlap(RegionFirstPage, RegionPages, FirstPage, EndPage: QWord;
  out OverlapFirst, OverlapEnd: QWord): Boolean;

implementation

function ChangedPageSpan(Offset, Length, PageCount: QWord; out FirstPage, EndPage: QWord): Boolean;
begin
  FirstPage := Offset div MappedPageBytes;
  if (Length = ChangeReachesEnd) or (Offset + Length < Offset) then
    EndPage := PageCount
  else
    EndPage := (Offset + Length + MappedPageBytes - 1) div MappedPageBytes;
  if EndPage > PageCount then
    EndPage := PageCount;
  if FirstPage > EndPage then
    FirstPage := EndPage;
  Result := (Length > 0) and (FirstPage < EndPage);
end;

procedure ChangedBytesInPage(PageIndex, Offset, Length: QWord; out Start, Finish: QWord);
var
  PageStart: QWord;
  ChangeEnd: QWord;
begin
  PageStart := PageIndex * MappedPageBytes;
  if (Length = ChangeReachesEnd) or (Offset + Length < Offset) then
    ChangeEnd := High(QWord)
  else
    ChangeEnd := Offset + Length;
  Start := 0;
  Finish := 0;
  if (ChangeEnd <= PageStart) or (Offset >= PageStart + MappedPageBytes) then
    Exit;
  if Offset > PageStart then
    Start := Offset - PageStart;
  if ChangeEnd >= PageStart + MappedPageBytes then
    Finish := MappedPageBytes
  else
    Finish := ChangeEnd - PageStart;
end;

function BytesBeforeEnd(PageIndex, FileSize: QWord): QWord;
var
  PageStart: QWord;
begin
  PageStart := PageIndex * MappedPageBytes;
  if PageStart >= FileSize then
    Exit(0);
  Result := FileSize - PageStart;
  if Result > MappedPageBytes then
    Result := MappedPageBytes;
end;

function MappedOverlap(RegionFirstPage, RegionPages, FirstPage, EndPage: QWord;
  out OverlapFirst, OverlapEnd: QWord): Boolean;
begin
  OverlapFirst := FirstPage;
  if RegionFirstPage > OverlapFirst then
    OverlapFirst := RegionFirstPage;
  OverlapEnd := EndPage;
  if RegionFirstPage + RegionPages < OverlapEnd then
    OverlapEnd := RegionFirstPage + RegionPages;
  Result := OverlapFirst < OverlapEnd;
  if not Result then
    OverlapEnd := OverlapFirst;
end;

end.

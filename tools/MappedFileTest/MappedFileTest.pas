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
  The arithmetic of mapped files on the host: page table entries with
  their flags (Processes.MappedPageEntries) and the ranges of changes,
  write-backs and mappings (Processes.MappedFileRanges), against a
  byte-by-byte model of the same.
}
program MappedFileTest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Processes.MappedPageEntries,
  Processes.MappedFileRanges;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if not Passed then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', Name);
  end;
end;

procedure TestEntries;
var
  Entry: QWord;
begin
  Entry := MakeMappedPageEntry($12345000, 0);
  Check('a clean entry keeps its address', MappedPagePhysical(Entry) = $12345000);
  Check('a clean entry is evictable', MappedPageIsEvictable(Entry));
  Check('a clean entry is not dirty', not MappedPageIsDirty(Entry));
  Entry := Entry or MappedPageDirty;
  Check('dirty', MappedPageIsDirty(Entry) and not MappedPageIsPreserved(Entry));
  Check('the address survives the flag', MappedPagePhysical(Entry) = $12345000);
  Check('a dirty entry is not evictable', not MappedPageIsEvictable(Entry));
  Entry := MakeMappedPageEntry($7000, MappedPagePreserved);
  Check('preserved', MappedPageIsPreserved(Entry) and not MappedPageIsDirty(Entry));
  Check('a preserved entry is not evictable', not MappedPageIsEvictable(Entry));
  Check('an empty entry is not evictable', not MappedPageIsEvictable(0));
  Check('flags of an unaligned address are cut off', MappedPagePhysical(MakeMappedPageEntry($7123, 0)) = $7000);
end;

{ The model: which pages of PageCount a change touches, byte by byte. }
function PageTouched(PageIndex, Offset, Length: QWord): Boolean;
var
  ByteIndex: QWord;
  ChangeEnd: QWord;
begin
  if Length = ChangeReachesEnd then
    ChangeEnd := High(QWord)
  else
    ChangeEnd := Offset + Length;
  for ByteIndex := PageIndex * MappedPageBytes to PageIndex * MappedPageBytes + MappedPageBytes - 1 do
    if (ByteIndex >= Offset) and (ByteIndex < ChangeEnd) then
      Exit(True);
  Result := False;
end;

procedure CheckChange(Offset, Length, PageCount: QWord);
var
  FirstPage: QWord;
  EndPage: QWord;
  Any: Boolean;
  PageIndex: QWord;
  Start: QWord;
  Finish: QWord;
  Expected: Boolean;
  Name: string;
begin
  Name := Format('change %d+%d of %d pages', [Offset, Int64(Length), PageCount]);
  Any := ChangedPageSpan(Offset, Length, PageCount, FirstPage, EndPage);
  PageIndex := 0;
  while PageIndex < PageCount do
  begin
    Expected := PageTouched(PageIndex, Offset, Length);
    Check(Name + Format(' page %d in the span', [PageIndex]),
      Expected = (Any and (PageIndex >= FirstPage) and (PageIndex < EndPage)));
    ChangedBytesInPage(PageIndex, Offset, Length, Start, Finish);
    Check(Name + Format(' page %d bytes', [PageIndex]), Expected = (Finish > Start));
    if Expected then
    begin
      Check(Name + ' first byte touched', PageTouched(PageIndex, Offset, Length) and
        ((Start = 0) or (PageIndex * MappedPageBytes + Start = Offset)));
      Check(Name + ' within the page', Finish <= MappedPageBytes);
    end;
    Inc(PageIndex);
  end;
end;

procedure TestChanges;
var
  FirstPage: QWord;
  EndPage: QWord;
begin
  CheckChange(0, 1, 4);
  CheckChange(4095, 2, 4);
  CheckChange(4096, 4096, 4);
  CheckChange(5000, 10, 4);
  CheckChange(100, 3 * MappedPageBytes, 4);
  CheckChange(2 * MappedPageBytes + 7, ChangeReachesEnd, 4);
  CheckChange(0, ChangeReachesEnd, 3);
  CheckChange(10 * MappedPageBytes, 5, 4);
  CheckChange(3 * MappedPageBytes + 4000, 500, 4);
  Check('an empty change touches nothing', not ChangedPageSpan(100, 0, 4, FirstPage, EndPage));
  Check('a change past the end touches nothing', not ChangedPageSpan(5 * MappedPageBytes, 10, 4, FirstPage, EndPage));
end;

procedure TestWriteBackLengths;
begin
  Check('a whole page before the end', BytesBeforeEnd(0, 10000) = MappedPageBytes);
  Check('the last page in part', BytesBeforeEnd(2, 10000) = 10000 - 2 * MappedPageBytes);
  Check('a page past the end', BytesBeforeEnd(3, 10000) = 0);
  Check('a page at the end exactly', BytesBeforeEnd(2, 2 * MappedPageBytes) = 0);
  Check('an empty file', BytesBeforeEnd(0, 0) = 0);
end;

procedure TestOverlaps;
var
  First: QWord;
  Finish: QWord;
begin
  Check('inside', MappedOverlap(10, 5, 11, 13, First, Finish) and (First = 11) and (Finish = 13));
  Check('covering', MappedOverlap(10, 5, 0, 100, First, Finish) and (First = 10) and (Finish = 15));
  Check('before', not MappedOverlap(10, 5, 0, 10, First, Finish));
  Check('after', not MappedOverlap(10, 5, 15, 20, First, Finish));
  Check('the last page', MappedOverlap(10, 5, 14, 15, First, Finish) and (First = 14) and (Finish = 15));
end;

begin
  TestEntries;
  TestChanges;
  TestWriteBackLengths;
  TestOverlaps;
  if Failures > 0 then
  begin
    WriteLn('MAPPED FILE TEST FAILED: ', Failures, ' of ', Checks, ' checks');
    Halt(1);
  end;
  WriteLn('MAPPED FILE TEST PASSED: ', Checks, ' checks');
end.

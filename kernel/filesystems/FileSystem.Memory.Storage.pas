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
  The contents of files on a memory volume (tmpfs).

  A file's data is kept in whole pages taken from the physical page
  allocator, reached through the physical memory window. Its page map
  is an array (on the kernel heap, grown by doubling) with the physical
  address of each page of the file, or 0 for a page never written (a
  hole, which reads as zeros). Every page counts against the volume's
  limit (the size= mount option); a write that would pass it fails with
  StatusNoSpace, as does one the allocator cannot serve. Shortening a
  file gives its pages back at once, and so does removing it
  (FileSystem.Memory frees a file's pages once its last name and its
  last open are gone).
}
unit FileSystem.Memory.Storage;

{$mode objfpc}
{$pointermath on}

interface

uses
  Memory.Layout,
  FileSystem.Types;

type
  PPageMap = ^TPhysicalAddress;

  { The pages of one file. }
  TFileStorage = record
    Pages: PPageMap;
    Capacity: QWord;
    { Pages actually allocated (holes not counted). }
    PageCount: QWord;
  end;

  { What a volume may still take. }
  PStorageBudget = ^TStorageBudget;
  TStorageBudget = record
    PageLimit: QWord;
    PagesUsed: QWord;
  end;

function ReadStorage(var Storage: TFileStorage; FileSize, Offset: QWord; Buffer: Pointer;
  ByteCount: QWord; out BytesRead: QWord): TFileSystemStatus;
{ Writes ByteCount bytes at Offset, allocating pages as needed; the
  file's size is the caller's to change. A write cut short by the limit
  reports how much went in (BytesWritten) and StatusNoSpace. }
function WriteStorage(var Storage: TFileStorage; Budget: PStorageBudget; Offset: QWord; Buffer: Pointer;
  ByteCount: QWord; out BytesWritten: QWord): TFileSystemStatus;
{ Frees every page from byte NewSize on and zeroes the rest of the page
  NewSize falls in. }
procedure TruncateStorage(var Storage: TFileStorage; Budget: PStorageBudget; NewSize: QWord);
{ Frees every page and the page map. }
procedure FreeStorage(var Storage: TFileStorage; Budget: PStorageBudget);

implementation

uses
  Runtime.Memory,
  Memory.KernelHeap,
  Memory.PhysicalPages;

const
  InitialMapCapacity = 4;

function PageAt(var Storage: TFileStorage; PageIndex: QWord): TPhysicalAddress;
begin
  if PageIndex >= Storage.Capacity then
    Exit(0);
  Result := Storage.Pages[PageIndex];
end;

{ Makes room in the page map for PageIndex. }
function GrowMap(var Storage: TFileStorage; PageIndex: QWord): Boolean;
var
  NewCapacity: QWord;
  NewPages: PPageMap;
begin
  if PageIndex < Storage.Capacity then
    Exit(True);
  NewCapacity := Storage.Capacity;
  if NewCapacity < InitialMapCapacity then
    NewCapacity := InitialMapCapacity;
  while NewCapacity <= PageIndex do
    NewCapacity := NewCapacity * 2;
  NewPages := PPageMap(AllocateZeroedKernelMemory(NewCapacity * SizeOf(TPhysicalAddress)));
  if NewPages = nil then
    Exit(False);
  if Storage.Pages <> nil then
  begin
    CopyMemory(NewPages, Storage.Pages, Storage.Capacity * SizeOf(TPhysicalAddress));
    FreeKernelMemory(Storage.Pages);
  end;
  Storage.Pages := NewPages;
  Storage.Capacity := NewCapacity;
  Result := True;
end;

{ The page holding PageIndex, allocated (zeroed) if it is a hole; 0 if
  the limit or the allocator says no. }
function PageForWriting(var Storage: TFileStorage; Budget: PStorageBudget; PageIndex: QWord): TPhysicalAddress;
begin
  Result := PageAt(Storage, PageIndex);
  if Result <> 0 then
    Exit;
  if Budget^.PagesUsed >= Budget^.PageLimit then
    Exit(0);
  if not GrowMap(Storage, PageIndex) then
    Exit(0);
  Result := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if Result = 0 then
    Exit;
  Storage.Pages[PageIndex] := Result;
  Inc(Storage.PageCount);
  Inc(Budget^.PagesUsed);
end;

function ReadStorage(var Storage: TFileStorage; FileSize, Offset: QWord; Buffer: Pointer;
  ByteCount: QWord; out BytesRead: QWord): TFileSystemStatus;
var
  Remaining: QWord;
  Position: QWord;
  WithinPage: QWord;
  Piece: QWord;
  Page: TPhysicalAddress;
  Destination: PByte;
begin
  BytesRead := 0;
  if Offset >= FileSize then
    Exit(StatusSuccess);
  Remaining := ByteCount;
  if Remaining > FileSize - Offset then
    Remaining := FileSize - Offset;
  Position := Offset;
  Destination := PByte(Buffer);
  while Remaining > 0 do
  begin
    WithinPage := Position and PageOffsetMask;
    Piece := PageSize - WithinPage;
    if Piece > Remaining then
      Piece := Remaining;
    Page := PageAt(Storage, Position shr PageShift);
    if Page = 0 then
      FillMemory(Destination, Piece, 0)
    else
      CopyMemory(Destination, PByte(PhysicalToVirtual(Page)) + WithinPage, Piece);
    Destination := Destination + Piece;
    Position := Position + Piece;
    Remaining := Remaining - Piece;
    BytesRead := BytesRead + Piece;
  end;
  Result := StatusSuccess;
end;

function WriteStorage(var Storage: TFileStorage; Budget: PStorageBudget; Offset: QWord; Buffer: Pointer;
  ByteCount: QWord; out BytesWritten: QWord): TFileSystemStatus;
var
  Remaining: QWord;
  Position: QWord;
  WithinPage: QWord;
  Piece: QWord;
  Page: TPhysicalAddress;
  Source: PByte;
begin
  BytesWritten := 0;
  Remaining := ByteCount;
  Position := Offset;
  Source := PByte(Buffer);
  while Remaining > 0 do
  begin
    WithinPage := Position and PageOffsetMask;
    Piece := PageSize - WithinPage;
    if Piece > Remaining then
      Piece := Remaining;
    Page := PageForWriting(Storage, Budget, Position shr PageShift);
    if Page = 0 then
      Exit(StatusNoSpace);
    if Source = nil then
      FillMemory(PByte(PhysicalToVirtual(Page)) + WithinPage, Piece, 0)
    else
    begin
      CopyMemory(PByte(PhysicalToVirtual(Page)) + WithinPage, Source, Piece);
      Source := Source + Piece;
    end;
    Position := Position + Piece;
    Remaining := Remaining - Piece;
    BytesWritten := BytesWritten + Piece;
  end;
  Result := StatusSuccess;
end;

procedure FreePageAt(var Storage: TFileStorage; Budget: PStorageBudget; PageIndex: QWord);
begin
  if Storage.Pages[PageIndex] = 0 then
    Exit;
  FreePhysicalPage(Storage.Pages[PageIndex]);
  Storage.Pages[PageIndex] := 0;
  Dec(Storage.PageCount);
  Dec(Budget^.PagesUsed);
end;

procedure TruncateStorage(var Storage: TFileStorage; Budget: PStorageBudget; NewSize: QWord);
var
  FirstFreed: QWord;
  PageIndex: QWord;
  WithinPage: QWord;
  Page: TPhysicalAddress;
begin
  FirstFreed := (NewSize + PageSize - 1) shr PageShift;
  PageIndex := FirstFreed;
  while PageIndex < Storage.Capacity do
  begin
    FreePageAt(Storage, Budget, PageIndex);
    Inc(PageIndex);
  end;
  WithinPage := NewSize and PageOffsetMask;
  if WithinPage <> 0 then
  begin
    Page := PageAt(Storage, NewSize shr PageShift);
    if Page <> 0 then
      FillMemory(PByte(PhysicalToVirtual(Page)) + WithinPage, PageSize - WithinPage, 0);
  end;
end;

procedure FreeStorage(var Storage: TFileStorage; Budget: PStorageBudget);
begin
  TruncateStorage(Storage, Budget, 0);
  FreeKernelMemory(Storage.Pages);
  Storage.Pages := nil;
  Storage.Capacity := 0;
  Storage.PageCount := 0;
end;

end.

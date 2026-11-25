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
  Sections: memory that several processes map at once, through handles
  (a window's pixels, shared between a program and the display server).

  A section is a number of zero filled physical pages, made when it is
  created. Mapping it (Processes.AddressSpace) takes a reference to each
  page, so pages live on while any process has them mapped, even after
  the last handle to the section is closed; the section holds one
  reference of its own, given back when it is deleted.

  Its pages are charged to whoever created it (ChargeHolder: a process,
  Processes.ObjectCalls) for as long as it exists; deleting it gives the
  charge back through ReleaseCharge.
}
unit Objects.Sections;

{$mode objfpc}
{$pointermath on}

interface

uses
  Memory.Layout;

const
  { 256 MiB: enough for a large screen's worth of pixels several times. }
  MaximumSectionBytes = QWord(256) * 1024 * 1024;

type
  TSectionChargeRelease = procedure(Holder: Pointer; Pages: QWord);

  PSectionObject = ^TSectionObject;
  TSectionObject = record
    PageCount: QWord;
    Pages: PPhysicalAddress;
    { Who its pages are charged to, and how the charge goes back (nil:
      charged to nobody). }
    ChargeHolder: Pointer;
    ReleaseCharge: TSectionChargeRelease;
  end;

procedure InitializeSectionObjects;
{ A section of Length bytes (rounded up to pages); nil if memory ran out
  or Length is 0 or too large. }
function CreateSectionObject(Length: QWord): PSectionObject;

implementation

uses
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Objects.Manager;

var
  SectionObjectType: TObjectType;

procedure FreeSectionPages(Section: PSectionObject);
var
  Index: QWord;
begin
  if Section^.Pages = nil then
    Exit;
  for Index := 0 to Section^.PageCount - 1 do
    if Section^.Pages[Index] <> 0 then
      FreePhysicalPage(Section^.Pages[Index]);
  FreeKernelMemory(Section^.Pages);
  Section^.Pages := nil;
end;

procedure DeleteSectionObject(ObjectBody: Pointer);
var
  Section: PSectionObject;
begin
  Section := PSectionObject(ObjectBody);
  FreeSectionPages(Section);
  if Assigned(Section^.ReleaseCharge) then
    Section^.ReleaseCharge(Section^.ChargeHolder, Section^.PageCount);
  Section^.ReleaseCharge := nil;
end;

procedure InitializeSectionObjects;
begin
  RegisterObjectType(SectionObjectType, 'Section', SizeOf(TSectionObject), @DeleteSectionObject);
end;

function CreateSectionObject(Length: QWord): PSectionObject;
var
  Index: QWord;
begin
  Result := nil;
  if (Length = 0) or (Length > MaximumSectionBytes) then
    Exit;
  Result := PSectionObject(CreateObject(SectionObjectType, nil));
  if Result = nil then
    Exit;
  Result^.PageCount := RoundUpToPage(Length) shr PageShift;
  Result^.Pages := AllocateZeroedKernelMemory(Result^.PageCount * SizeOf(TPhysicalAddress));
  if Result^.Pages = nil then
  begin
    DereferenceObject(Result);
    Exit(nil);
  end;
  for Index := 0 to Result^.PageCount - 1 do
  begin
    Result^.Pages[Index] := AllocateZeroedPhysicalPage(PageUsageSection);
    if Result^.Pages[Index] = 0 then
    begin
      DereferenceObject(Result);
      Exit(nil);
    end;
  end;
end;

end.

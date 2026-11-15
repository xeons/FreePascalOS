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
  Mapping a handle's memory into the program.

  CallMapHandle maps Length bytes at Offset of what a handle stands for:
  a device that offers memory (the display's framebuffer), or a section.
  For a device, the driver says which physical memory that is and
  whether writes may be combined (Io.DeviceFiles.QueryDeviceMapping);
  the pages go into a device region of the address space
  (Processes.AddressSpace), writable if the handle was opened for
  writing. A section's pages are mapped writable, each with a reference
  of its own. The program unmaps it with
  CallFreeMemory, and it goes with the address space otherwise; the
  device's memory is never freed by either.
}
unit Processes.MappingCalls;

{$mode objfpc}

interface

function PerformMapHandle(Handle: Int64; Offset, Length: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Memory.Layout,
  Kernel.Mutex,
  Io.Manager,
  Io.DeviceFiles,
  Objects.Manager,
  Processes.Handles,
  Processes.Process,
  Processes.Thread,
  Processes.AddressSpace,
  Processes.ObjectCalls,
  Objects.Sections;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

{ The device file behind Handle, referenced; nil if it is not one. }
function ReferenceDeviceFile(Handle: Int64): PDeviceFile;
var
  Process: PProcess;
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  Result := nil;
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  if LookupHandle(Process^.Handles, Handle, Kind, ObjectBody) and (Kind = HandleKindDevice) then
  begin
    ReferenceObject(ObjectBody);
    Result := PDeviceFile(ObjectBody);
  end;
  ReleaseMutex(Process^.Lock);
end;

function MapSection(Handle: Int64; Offset, Length: QWord): Int64;
var
  Section: PSectionObject;
  Error: LongInt;
  Start: QWord;
  FirstPage: QWord;
begin
  Section := PSectionObject(ReferenceHandleOfKind(Handle, HandleKindSection));
  if Section = nil then
    Exit(Failure(ErrorBadHandle));
  FirstPage := Offset shr PageShift;
  if (FirstPage >= Section^.PageCount) or ((Length shr PageShift) > Section^.PageCount - FirstPage) then
    Error := ErrorInvalidArgument
  else
    Error := MapPagesIntoAddressSpace(CurrentProcess^.AddressSpace, Section^.Pages + FirstPage,
      Length shr PageShift, True, Start);
  DereferenceObject(Section);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := Int64(Start);
end;

function PerformMapHandle(Handle: Int64; Offset, Length: QWord): Int64;
var
  OpenFile: PDeviceFile;
  Physical: QWord;
  WriteCombining: Boolean;
  Error: LongInt;
  Start: QWord;
begin
  if (Length = 0) or ((Offset and PageOffsetMask) <> 0) then
    Exit(Failure(ErrorInvalidArgument));
  Length := RoundUpToPage(Length);
  OpenFile := ReferenceDeviceFile(Handle);
  if OpenFile = nil then
    Exit(MapSection(Handle, Offset, Length));
  Error := QueryDeviceMapping(OpenFile, Offset, Length, Physical, WriteCombining);
  if Error = ErrorNone then
    Error := MapDeviceIntoAddressSpace(CurrentProcess^.AddressSpace, Physical, Length,
      (OpenFile^.OpenFlags and OpenWrite) <> 0, WriteCombining, Start);
  DereferenceObject(OpenFile);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := Int64(Start);
end;

end.

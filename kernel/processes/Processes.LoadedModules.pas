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
  Where a process's program and libraries were loaded, for crash
  reports: an address in a report means something only together with
  the module it lies in and that module's load base (which differs from
  run to run once modules load at random addresses).

  CallGetProcessModules hands the list to the program (the runtime's
  report of an unhandled exception names each address's module and
  lists the modules, rtl/fpc); the kernel's own report of a program it
  had to end (Processes.UserProcess) writes them to the kernel log:

    [process]   module coretest at 0x0000000000400000-0x0000000000452000
    [process]   module libsystem.so at 0x00007F0000000000-0x...

  scripts/symbolize.py reads both forms. The module list
  (Processes.ImageLoader) changes under the process's lock.
}
unit Processes.LoadedModules;

{$mode objfpc}

interface

uses
  Processes.Process;

function PerformGetProcessModules(BufferAddress: QWord; Capacity: QWord): Int64;

{ Writes the modules of Process to the kernel log, one line each, after
  the tag. Takes the process's lock. }
procedure WriteProcessModules(Process: PProcess; Tag: PChar);

{ Writes " (module+0x1C)" for an address inside one of Process's
  modules, nothing otherwise. Reads the list without the lock (for
  reports made with interrupts disabled): the list only grows, and a
  module is freed only when the process ends. }
procedure WriteModuleOfAddress(Process: PProcess; Address: QWord);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Kernel.Mutex,
  Processes.ImageLoader,
  Processes.Thread,
  Processes.UserAccess,
  Debug.Output;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function ModulesOf(Process: PProcess): PModuleList;
begin
  Result := PModuleList(Process^.Modules);
end;

procedure DescribeModule(Module: PLoadedModule; out Information: TAbiModuleInformation);
begin
  FillMemory(@Information, SizeOf(Information), 0);
  Information.Base := Module^.Base;
  Information.Limit := Module^.Limit;
  CopyText(@Information.Name[0], @Module^.Name[0], AbiModuleNameCapacity);
end;

function PerformGetProcessModules(BufferAddress: QWord; Capacity: QWord): Int64;
var
  Process: PProcess;
  List: PModuleList;
  Index: Integer;
  Information: TAbiModuleInformation;
  Error: LongInt;
begin
  Process := CurrentProcess;
  Result := 0;
  Error := ErrorNone;
  AcquireMutex(Process^.Lock);
  List := ModulesOf(Process);
  if List <> nil then
  begin
    Result := List^.Count;
    Index := 0;
    while (Index < List^.Count) and (QWord(Index) < Capacity) and (Error = ErrorNone) do
    begin
      DescribeModule(List^.Modules[Index], Information);
      Error := CopyToUser(BufferAddress + QWord(Index) * SizeOf(Information), @Information,
        SizeOf(Information));
      Inc(Index);
    end;
  end;
  ReleaseMutex(Process^.Lock);
  if Error <> ErrorNone then
    Result := Failure(Error);
end;

procedure WriteProcessModules(Process: PProcess; Tag: PChar);
var
  List: PModuleList;
  Index: Integer;
  Module: PLoadedModule;
begin
  AcquireMutex(Process^.Lock);
  List := ModulesOf(Process);
  if List <> nil then
    for Index := 0 to List^.Count - 1 do
    begin
      Module := List^.Modules[Index];
      DebugBeginMessage;
      DebugWriteTag(Tag);
      DebugWrite('  module ');
      DebugWrite(@Module^.Name[0]);
      DebugWrite(' at ');
      DebugWriteAddress(Module^.Base);
      DebugWrite('-');
      DebugWriteAddress(Module^.Limit);
      DebugWriteLine('');
      DebugEndMessage;
    end;
  ReleaseMutex(Process^.Lock);
end;

procedure WriteModuleOfAddress(Process: PProcess; Address: QWord);
var
  List: PModuleList;
  Index: Integer;
  Module: PLoadedModule;
begin
  List := ModulesOf(Process);
  if List = nil then
    Exit;
  for Index := 0 to List^.Count - 1 do
  begin
    Module := List^.Modules[Index];
    if (Module <> nil) and (Address >= Module^.Base) and (Address < Module^.Limit) then
    begin
      DebugBeginMessage;
      DebugWrite(' (');
      DebugWrite(@Module^.Name[0]);
      DebugWrite('+0x');
      DebugWriteHex(Address - Module^.Base, 1);
      DebugWrite(')');
      DebugEndMessage;
      Exit;
    end;
  end;
end;

end.

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
  Restrictions a process puts on itself (CallSetProcessLimit with
  ProcessLimitRestrictions): a sandbox for programs that run what they
  cannot trust, the browser's content processes first. A flag once set
  stays for the life of the process and goes to every process it
  starts; root is held to them like anyone. The system calls that a
  flag forbids ask CallerRestricted; RestrictFileReads also limits which
  paths may be opened or looked at (RestrictedPathReadable): those
  under /lib and /etc, which hold what any program needs to run
  (libraries, fonts, the system's settings) and nothing of the user's.
}
unit Processes.Restrictions;

{$mode objfpc}

interface

{ Adds Value's flags to the caller's restrictions; returns the flags
  before (ProcessLimitRestrictions). }
function AddRestrictions(Value: QWord): Int64;
{ The calling user process has any of Flags. }
function CallerRestricted(Flags: LongWord): Boolean;
{ A path as the kernel sees it (the system volume's name first) that a
  process restricted to reading the system's files may open or look at:
  /lib and /etc of the system volume, nothing of other volumes. }
function RestrictedPathReadable(Path: PChar): Boolean;
{ A device (its name under /dev) such a process may open. }
function RestrictedDeviceReadable(Name: PChar): Boolean;
{ ErrorAccessDenied when the caller may not write files, else ErrorNone. }
function CheckFileWrite: LongInt;

implementation

uses
  Runtime.Text,
  Runtime.Memory,
  Processes.Paths,
  Abi.SystemCalls,
  Kernel.Mutex,
  Processes.Process,
  Processes.Thread;

function AddRestrictions(Value: QWord): Int64;
var
  Process: PProcess;
begin
  if (Value and not QWord(RestrictionsAll)) <> 0 then
    Exit(-Int64(ErrorInvalidArgument));
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Result := Int64(Process^.Restrictions);
  Process^.Restrictions := Process^.Restrictions or LongWord(Value);
  ReleaseMutex(Process^.Lock);
end;

function CallerRestricted(Flags: LongWord): Boolean;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  Result := Process^.IsUserProcess and ((Process^.Restrictions and Flags) <> 0);
end;

function CheckFileWrite: LongInt;
begin
  if CallerRestricted(RestrictFileWrites) then
    Result := ErrorAccessDenied
  else
    Result := ErrorNone;
end;

{ Path (a kernel path) is the system volume's Folder itself or
  something under it. }
function PathIsUnder(Path: PChar; Folder: PChar): Boolean;
var
  Prefix: array[0..127] of Char;
  Length_: PtrUInt;
begin
  SystemVolumePath(Folder, @Prefix[0], SizeOf(Prefix));
  Length_ := TextLength(@Prefix[0]);
  Result := MemoryIsEqual(Path, @Prefix[0], Length_) and ((Path[Length_] = #0) or (Path[Length_] = '/'));
end;

{ A ".." anywhere could climb out of the allowed folders (the path is
  normally resolved already; this is for safety). }
function HasParentStep(Path: PChar): Boolean;
var
  Index: Integer;
begin
  Index := 0;
  while Path[Index] <> #0 do
  begin
    if (Path[Index] = '.') and (Path[Index + 1] = '.') and ((Index = 0) or (Path[Index - 1] = '/')) and
       ((Path[Index + 2] = '/') or (Path[Index + 2] = #0)) then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

function RestrictedPathReadable(Path: PChar): Boolean;
begin
  if (Path = nil) or HasParentStep(Path) then
    Exit(False);
  Result := PathIsUnder(Path, '/lib') or PathIsUnder(Path, '/etc');
end;

function RestrictedDeviceReadable(Name: PChar): Boolean;
begin
  Result := TextIsEqual(Name, 'null') or TextIsEqual(Name, 'random') or TextIsEqual(Name, 'urandom');
end;

end.

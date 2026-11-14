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
  Console settings: echo and line editing, and the screen size.
}
unit Sys.Console;

{$mode objfpc}

interface

{ True if Handle is the console. }
function IsConsole(Handle: Int64): Boolean;
{ ConsoleModeEcho and ConsoleModeLineEditing bits, or a negative error. }
function GetConsoleMode(Handle: Int64): Int64;
function SetConsoleMode(Handle: Int64; Mode: LongWord): LongInt;
procedure GetConsoleSize(Handle: Int64; out Rows, Columns: LongInt);
{ The process group that Ctrl-C ends. }
function SetForegroundGroup(Handle: Int64; GroupId: Int64): LongInt;
function GetForegroundGroup(Handle: Int64): Int64;
{ True once for each Ctrl-C that was passed to the console's reader
  while it was not reading (see ControlTakePendingInterrupt). }
function TakePendingInterrupt(Handle: Int64): Boolean;

implementation

uses
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Errors;

function IsConsole(Handle: Int64): Boolean;
begin
  Result := KernelGetHandleKind(Handle) = HandleKindConsole;
end;

function GetConsoleMode(Handle: Int64): Int64;
begin
  Result := KernelControlHandle(Handle, ControlGetConsoleMode, 0);
end;

function SetConsoleMode(Handle: Int64; Mode: LongWord): LongInt;
begin
  Result := ErrorCodeOf(KernelControlHandle(Handle, ControlSetConsoleMode, Mode));
end;

function SetForegroundGroup(Handle: Int64; GroupId: Int64): LongInt;
begin
  Result := ErrorCodeOf(KernelControlHandle(Handle, ControlSetForegroundGroup, QWord(GroupId)));
end;

function GetForegroundGroup(Handle: Int64): Int64;
begin
  Result := KernelControlHandle(Handle, ControlGetForegroundGroup, 0);
end;

function TakePendingInterrupt(Handle: Int64): Boolean;
begin
  Result := KernelControlHandle(Handle, ControlTakePendingInterrupt, 0) = 1;
end;

procedure GetConsoleSize(Handle: Int64; out Rows, Columns: LongInt);
var
  Size: Int64;
begin
  Size := KernelControlHandle(Handle, ControlGetConsoleSize, 0);
  if Size < 0 then
  begin
    Rows := 24;
    Columns := 80;
    Exit;
  end;
  Rows := LongInt(Size shr 16);
  Columns := LongInt(Size and $FFFF);
end;

end.

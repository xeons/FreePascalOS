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

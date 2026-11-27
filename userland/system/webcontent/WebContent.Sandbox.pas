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
  What a content process does to itself before it runs any page: the
  kernel's restrictions (Processes.Restrictions: no sockets, no file
  writes, reads only under /lib and /etc, no programs started, no ports,
  no other process controlled), a limit on the memory it may commit,
  and a high out-of-memory score - higher still while none of its
  views is shown - so that when memory runs out a background renderer
  goes before the browser. Its priority class follows the same way
  (Kernel.PriorityClasses): Background while a view of it is shown, so
  a page's scripts and layout never hold up the browser's window (which
  runs Normal), the desktop or the display server; Idle while none is,
  so a hidden tab gets the processor only when nothing else wants it.
}
unit WebContent.Sandbox;

{$mode objfpc}
{$H+}

interface

const
  { Out-of-memory adjustments (Processes.OutOfMemoryScores). }
  ForegroundOomAdjust = 300;
  BackgroundOomAdjust = 700;

{ Restricts this process (unless Restrict is False) and limits its
  memory (MemoryLimitMegabytes, 0: none). Returns what was done, for
  the log. }
function EnterSandbox(Restrict: Boolean; MemoryLimitMegabytes: LongWord): string;
{ The out-of-memory adjustment for a process whose views are (not) shown. }
procedure SetShown(Shown: Boolean);

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Restrictions,
  Sys.MemoryStatus,
  Sys.PriorityClasses;

var
  LastShown: LongInt = -1;

function EnterSandbox(Restrict: Boolean; MemoryLimitMegabytes: LongWord): string;
var
  Error: LongInt;
begin
  Result := '';
  if MemoryLimitMegabytes > 0 then
  begin
    Error := LimitCommittedMemory(QWord(MemoryLimitMegabytes) * 1024 * 1024);
    if Error = ErrorNone then
      Result := 'memory ' + IntToStr(MemoryLimitMegabytes) + ' MiB'
    else
      Result := 'memory limit refused (' + IntToStr(Error) + ')';
  end;
  SetShown(False);
  if not Restrict then
    Exit(Result + ', not sandboxed');
  Error := RestrictThisProcess(RestrictionsAll);
  if Error = ErrorNone then
    Result := Result + ', sandboxed'
  else
    Result := Result + ', sandbox refused (' + IntToStr(Error) + ')';
end;

procedure SetShown(Shown: Boolean);
var
  Previous: LongInt;
begin
  if Ord(Shown) = LastShown then
    Exit;
  LastShown := Ord(Shown);
  if Shown then
  begin
    SetOomScoreAdjust(ForegroundOomAdjust, Previous);
    SetPriorityClass(0, PriorityClassBackground);
  end
  else
  begin
    SetOomScoreAdjust(BackgroundOomAdjust, Previous);
    SetPriorityClass(0, PriorityClassIdle);
  end;
end;

end.

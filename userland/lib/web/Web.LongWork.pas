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
  Steps of the engine's own long work: work of known, finite length
  that runs in one go on the page thread, such as running the platform
  scripts when a window's realm is made (Web.Script.Natives; a few
  seconds on a slow emulator). After each step it calls
  NoteLongWorkStep, and the program may do what must not wait that
  long: a content process answers its browser's pings
  (WebContent.Process), so a renderer that is busy starting up is not
  taken for a hung one. Page scripts never call it: a script that loops
  for ever leaves the pings unanswered, which is how the browser tells.

  The handler runs on the page thread, at most once per
  LongWorkStepInterval milliseconds.
}
unit Web.LongWork;

{$mode objfpc}

interface

type
  TLongWorkStepEvent = procedure of object;

const
  LongWorkStepInterval = 100;

{ The program's handler (nil: none). }
procedure SetLongWorkStepHandler(Handler: TLongWorkStepEvent);
{ One step of long work is done. }
procedure NoteLongWorkStep;

implementation

uses
  SysUtils;

var
  StepHandler: TLongWorkStepEvent = nil;
  LastStepCall: QWord = 0;

procedure SetLongWorkStepHandler(Handler: TLongWorkStepEvent);
begin
  StepHandler := Handler;
end;

procedure NoteLongWorkStep;
var
  Now: QWord;
begin
  if not Assigned(StepHandler) then
    Exit;
  Now := GetTickCount64;
  if Now - LastStepCall < LongWorkStepInterval then
    Exit;
  LastStepCall := Now;
  StepHandler();
end;

end.

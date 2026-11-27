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
  The processes whose programs have stopped responding: the display
  server marks the windows of a program that no longer answers its
  pings (ShellWindowNotResponding). The Programs tab notes them at each
  look; the Processes tab shows them, and ending one does not ask it
  first - it could not answer.
}
unit TaskManager.NotResponding;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.WindowList;

{ Notes which processes have a window that does not respond. }
procedure NoteListedWindows(const Windows: TListedWindows);
function IsNotResponding(ProcessId: QWord): Boolean;

implementation

uses
  Windowing.Protocol;

var
  NotResponding: array of QWord;

procedure NoteListedWindows(const Windows: TListedWindows);
var
  Index: LongInt;
begin
  NotResponding := nil;
  for Index := 0 to High(Windows) do
    if ((Windows[Index].Flags and ShellWindowNotResponding) <> 0) and
       not IsNotResponding(Windows[Index].ProcessId) then
      Insert(Windows[Index].ProcessId, NotResponding, Length(NotResponding));
end;

function IsNotResponding(ProcessId: QWord): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to High(NotResponding) do
    if NotResponding[Index] = ProcessId then
      Exit(True);
  Result := False;
end;

end.

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
  The other programs' windows, for a program that is not the shell (a
  task manager): their titles, what state they are in and the process
  each belongs to (RequestListWindows). The server lists the windows of
  the programs of the same user (root: of all), and those are the ones
  a program may switch to, minimize or close (Windowing.Shell's
  ManageWindow).

  The call sends the request and waits for the whole list; other events
  that arrive meanwhile are kept (Windowing.Connection). The program
  must be connected (ConnectToDisplay).
}
unit Windowing.WindowList;

{$mode objfpc}
{$H+}

interface

type
  TListedWindow = record
    Id: LongWord;
    { The process of the program it belongs to. }
    ProcessId: QWord;
    { ShellWindow*. }
    Flags: LongWord;
    { The display it is on. }
    Display: LongInt;
    Title: string;
  end;
  TListedWindows = array of TListedWindow;

{ Fills Windows with the other programs' top-level windows, in the
  order the server keeps them (the first made first); False if the
  server did not answer. }
function ListOtherWindows(out Windows: TListedWindows): Boolean;

implementation

uses
  Windowing.Protocol,
  Windowing.Connection;

const
  ReplyTimeout = 5000;

function ListOtherWindows(out Windows: TListedWindows): Boolean;
var
  Message: TWindowMessage;
  Count: LongInt;
begin
  Windows := nil;
  Message := NewMessage(RequestListWindows, 0);
  SendRequest(Message, -1);
  Count := 0;
  repeat
    if not WaitForEvent(EventWindowListed, ReplyTimeout, Message) then
      Exit(False);
    if Message.Window = 0 then
      Break;
    SetLength(Windows, Count + 1);
    Windows[Count].Id := Message.Window;
    Windows[Count].ProcessId := QWord(LongWord(Message.Value));
    Windows[Count].Flags := Message.Flags;
    Windows[Count].Display := LongInt(Message.Code);
    Message.Text[TitleCapacity - 1] := #0;
    Windows[Count].Title := StrPas(@Message.Text[0]);
    Inc(Count);
  until False;
  Result := True;
end;

end.

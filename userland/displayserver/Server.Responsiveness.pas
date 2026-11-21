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
  Which programs still serve their windows.

  A program whose message loop answers pings (it said so in its hello,
  HelloAnswersPings: every program built on libwindowing) and that has
  windows is sent an EventPing every PingIntervalMilliseconds; its loop
  answers with RequestAnswerPing. One that has left a ping unanswered
  for NotRespondingAfterMilliseconds is not responding - busy in a long
  computation, or stuck - and its windows say so: "(Not responding)"
  after their titles, and ShellWindowNotResponding in what the shell
  and a task manager hear (Server.Shell, Server.WindowList), so the
  user knows to end it. The first answer after that makes it
  responding again.

  The server never waits for an answer: a ping is one message, sent
  only when the one before was answered, so a stuck program's queue
  does not fill with them.
}
unit Server.Responsiveness;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Protocol,
  Server.Clients;

const
  PingIntervalMilliseconds = 2000;
  NotRespondingAfterMilliseconds = 5000;

{ Sends the pings that are due and notes programs that have not
  answered in time. Called on every turn of the server's loop. }
procedure CheckClientsResponding;
{ How long the server's loop may wait before CheckClientsResponding
  has something to do (InfiniteWait: nothing to watch). }
function ResponsivenessWaitTime: Int64;
{ Client answered ping number Value. }
procedure NoteAnswerToPing(Client: TClient; Value: LongInt);

implementation

uses
  Abi.SystemCalls,
  Sys.Time,
  Server.Windows,
  Server.Composer;

var
  NextPingNumber: LongInt = 1;

function HasWindows(Client: TClient): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to WindowCount - 1 do
    if Windows[Index].Client = Client then
      Exit(True);
  Result := False;
end;

{ Marks Client's windows as (not) responding and draws their frames
  again; the shell hears through the state flags. }
procedure SetNotResponding(Client: TClient; NotResponding: Boolean);
var
  Index: LongInt;
  Window: TServerWindow;
begin
  Client.NotResponding := NotResponding;
  for Index := 0 to WindowCount - 1 do
  begin
    Window := Windows[Index];
    if Window.Client <> Client then
      Continue;
    Window.NotResponding := NotResponding;
    if Window.Visible then
      DamageWindow(Window);
  end;
end;

procedure SendPing(Client: TClient; Now: QWord);
var
  Message: TWindowMessage;
begin
  Client.PingNumber := NextPingNumber;
  Inc(NextPingNumber);
  if NextPingNumber <= 0 then
    NextPingNumber := 1;
  Client.PingSentAt := Now;
  Client.PingOutstanding := True;
  Message := NewMessage(EventPing, 0);
  Message.Value := Client.PingNumber;
  SendToClient(Client, Message);
end;

procedure CheckClientsResponding;
var
  Index: LongInt;
  Client: TClient;
  Now: QWord;
begin
  Now := UptimeMilliseconds;
  for Index := 0 to ClientCount - 1 do
  begin
    Client := Clients[Index];
    if not Client.AnswersPings then
      Continue;
    if Client.PingOutstanding then
    begin
      if not Client.NotResponding and (Now - Client.PingSentAt >= NotRespondingAfterMilliseconds) then
        SetNotResponding(Client, True);
    end
    else if (Now - Client.PingSentAt >= PingIntervalMilliseconds) and HasWindows(Client) then
      SendPing(Client, Now);
  end;
end;

function ResponsivenessWaitTime: Int64;
var
  Index: LongInt;
  Client: TClient;
  Now: QWord;
  Due: QWord;
  Soonest: QWord;
begin
  Result := InfiniteWait;
  Now := UptimeMilliseconds;
  Soonest := High(QWord);
  for Index := 0 to ClientCount - 1 do
  begin
    Client := Clients[Index];
    if not Client.AnswersPings or Client.NotResponding then
      Continue;
    if not Client.PingOutstanding and not HasWindows(Client) then
      Continue;
    if Client.PingOutstanding then
      Due := Client.PingSentAt + NotRespondingAfterMilliseconds
    else
      Due := Client.PingSentAt + PingIntervalMilliseconds;
    if Due < Soonest then
      Soonest := Due;
  end;
  if Soonest = High(QWord) then
    Exit;
  if Soonest <= Now then
    Result := 0
  else
    Result := Int64(Soonest - Now);
end;

procedure NoteAnswerToPing(Client: TClient; Value: LongInt);
begin
  if not Client.PingOutstanding or (Value <> Client.PingNumber) then
    Exit;
  Client.PingOutstanding := False;
  if Client.NotResponding then
    SetNotResponding(Client, False);
end;

end.

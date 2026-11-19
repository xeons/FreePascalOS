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
  How a program's single loop serves many channels and listeners: each
  names the handles it waits on now and what to do when one is ready
  (CollectWaits, a list of handle and method), and is polled after every
  wait (Poll) to move what the wait could not show - input written by a
  thread, a program ended, a connection made.

    Waits := nil;
    for each channel: Channel.CollectWaits(Waits);
    Ready := WaitForHandles(handles of Waits, timeout);
    Waits[Ready].OnReady();
    for each channel: Channel.Poll;
    Connection.Flush;

  A channel that has to be looked at soon without a handle to wait on (a
  socket still connecting) says so with WantsQuickPoll, and the loop
  waits briefly.
}
unit Ssh.PolledChannels;

{$mode objfpc}{$H+}

interface

uses
  Ssh.Connection;

type
  TSshReadyEvent = procedure of object;

  TSshWait = record
    Handle: Int64;
    OnReady: TSshReadyEvent;
  end;
  TSshWaitList = array of TSshWait;

  TSshPolledChannel = class(TSshChannel)
  public
    procedure CollectWaits(var Waits: TSshWaitList); virtual;
    procedure Poll; virtual;
    function WantsQuickPoll: Boolean; virtual;
  end;

procedure AddWait(var Waits: TSshWaitList; Handle: Int64; OnReady: TSshReadyEvent);
{ CollectWaits and Poll of every polled channel of Connection. }
procedure CollectChannelWaits(Connection: TSshConnection; var Waits: TSshWaitList);
procedure PollChannels(Connection: TSshConnection);
function AnyChannelWantsQuickPoll(Connection: TSshConnection): Boolean;

implementation

procedure AddWait(var Waits: TSshWaitList; Handle: Int64; OnReady: TSshReadyEvent);
begin
  SetLength(Waits, Length(Waits) + 1);
  Waits[High(Waits)].Handle := Handle;
  Waits[High(Waits)].OnReady := OnReady;
end;

procedure TSshPolledChannel.CollectWaits(var Waits: TSshWaitList);
begin
end;

procedure TSshPolledChannel.Poll;
begin
end;

function TSshPolledChannel.WantsQuickPoll: Boolean;
begin
  Result := False;
end;

procedure CollectChannelWaits(Connection: TSshConnection; var Waits: TSshWaitList);
var
  Index: Integer;
begin
  if Connection = nil then
    Exit;
  for Index := 0 to Connection.ChannelCount - 1 do
    if Connection.ChannelAt(Index) is TSshPolledChannel then
      TSshPolledChannel(Connection.ChannelAt(Index)).CollectWaits(Waits);
end;

procedure PollChannels(Connection: TSshConnection);
var
  Index: Integer;
begin
  if Connection = nil then
    Exit;
  for Index := 0 to Connection.ChannelCount - 1 do
    if Connection.ChannelAt(Index) is TSshPolledChannel then
      TSshPolledChannel(Connection.ChannelAt(Index)).Poll;
end;

function AnyChannelWantsQuickPoll(Connection: TSshConnection): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if Connection = nil then
    Exit;
  for Index := 0 to Connection.ChannelCount - 1 do
    if (Connection.ChannelAt(Index) is TSshPolledChannel) and
      TSshPolledChannel(Connection.ChannelAt(Index)).WantsQuickPoll then
      Exit(True);
end;

end.

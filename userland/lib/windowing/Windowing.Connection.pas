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
  The connection to the display server: one per program.

  ConnectToDisplay connects to the server's port and says hello; the
  answer tells the first display's size, DPI and scale, kept here for
  everyone. Messages are sent with SendRequest; WaitForEvent waits for
  one of a kind (a reply) and keeps whatever else arrives meanwhile for
  NextEvent, so nothing is lost or taken out of order.

  Each window is at the scale of the display it is on, so the scale
  used for converting between logical units and pixels (DisplayScale,
  DisplayDpi, Scaled, Unscaled) is the one of the window being served:
  Windowing.Windows selects it (UseScale) before a window's handlers
  run, before it paints and before a queued message reaches it or its
  controls. DefaultScale and DefaultDpi are the first display's, which a
  new window starts at; they change with it (EventScaleChanged for
  window 0, TakeScaleChange).

  Most events carry no handle, and a handle that comes with one is
  closed; the data the clipboard and drags deliver comes in a section
  (EventDataDelivered), kept for the program (TakeMessageHandle). A
  request to give the clipboard's or a drag's data (EventDataRender) is
  handed to DataRenderHandler as soon as it arrives, whatever the
  program is waiting for, so a program pasting what it offered itself,
  or waiting for another reply meanwhile, never keeps the server (and
  the program asking) waiting.
}
unit Windowing.Connection;

{$mode objfpc}

interface

uses
  Windowing.Protocol;

type
  TDataRenderHandler = procedure(const Message: TWindowMessage);

var
  DisplayChannel: Int64 = -1;
  { Gets every EventDataRender as it arrives (Windowing.DataTransfer). }
  DataRenderHandler: TDataRenderHandler;
  ScreenWidth: LongInt;
  ScreenHeight: LongInt;
  { The scale and DPI in use: the window being served's. }
  DisplayDpi: LongWord = 96;
  DisplayScale: LongWord = 100;
  { The first display's: where new windows start. }
  DefaultDpi: LongWord = 96;
  DefaultScale: LongWord = 100;

{ ErrorNone, or an error code (no display server: ErrorNotFound). Waits a
  little for the server, as it may still be starting, unless
  WaitForServer is False (a program that only reports what it finds, and
  runs in text mode too, should not wait for a server that never comes). }
function ConnectToDisplay(WaitForServer: Boolean = True): LongInt;
procedure DisconnectFromDisplay;
function IsConnected: Boolean;

{ A length in logical units in pixels, and back, at the display's scale. }
function Scaled(Logical: LongInt): LongInt;
function Unscaled(Pixels: LongInt): LongInt;

{ Sends Message (with Handle if not negative; the handle stays ours). }
procedure SendRequest(var Message: TWindowMessage; Handle: Int64);
{ The next message of Kind, waiting up to Timeout milliseconds; others
  that arrive are kept. False on timeout or a broken connection. }
function WaitForEvent(Kind: LongWord; Timeout: Int64; out Message: TWindowMessage): Boolean;
{ A message kept or waiting on the channel, without waiting; False if
  none. }
function NextEvent(out Message: TWindowMessage): Boolean;
{ The handle a message came with (a section), now the caller's to close;
  -1 if it had none or it was taken already. }
function TakeMessageHandle(var Message: TWindowMessage): Int64;
{ True once the server is gone. }
function ConnectionBroken: Boolean;
{ Takes the first display's size, DPI and scale from EventScaleChanged
  for window 0. }
procedure TakeScaleChange(const Message: TWindowMessage);
{ Converts at ScalePercent and Dpi from now on (a window's). }
procedure UseScale(ScalePercent, Dpi: LongWord);

implementation

uses
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Processes,
  Windowing.ThemeSettings;

const
  ConnectAttempts = 50;
  ConnectPause = 100;
  ReplyTimeout = 5000;

var
  { Events that came while waiting for a reply, oldest first. }
  Kept: array of TWindowMessage;
  Broken: Boolean;
  { Handles that came with messages, until taken: a message's Reserved
    is its place here plus one. }
  ReceivedHandles: array of Int64;

{ Whether a handle coming with a message of Kind is kept for the program. }
function KeepsHandle(Kind: LongWord): Boolean;
begin
  Result := (Kind = EventDataDelivered) or (Kind = EventWindowIconDescribed);
end;

function StoreReceivedHandle(Handle: Int64): LongWord;
var
  Index: LongInt;
begin
  for Index := 0 to High(ReceivedHandles) do
    if ReceivedHandles[Index] < 0 then
    begin
      ReceivedHandles[Index] := Handle;
      Exit(Index + 1);
    end;
  Insert(Handle, ReceivedHandles, Length(ReceivedHandles));
  Result := Length(ReceivedHandles);
end;

function TakeMessageHandle(var Message: TWindowMessage): Int64;
var
  Place: LongInt;
begin
  Result := -1;
  Place := LongInt(Message.Reserved) - 1;
  Message.Reserved := 0;
  if (Place < 0) or (Place > High(ReceivedHandles)) then
    Exit;
  Result := ReceivedHandles[Place];
  ReceivedHandles[Place] := -1;
end;

function IsConnected: Boolean;
begin
  Result := (DisplayChannel >= 0) and not Broken;
end;

function ConnectionBroken: Boolean;
begin
  Result := Broken;
end;

function Scaled(Logical: LongInt): LongInt;
begin
  Result := LogicalToPixels(Logical, DisplayScale);
end;

function Unscaled(Pixels: LongInt): LongInt;
begin
  Result := PixelsToLogical(Pixels, DisplayScale);
end;

procedure SendRequest(var Message: TWindowMessage; Handle: Int64);
begin
  if DisplayChannel < 0 then
    Exit;
  if Handle >= 0 then
    SendMessage(DisplayChannel, @Message, SizeOf(Message), [Handle])
  else
    SendMessage(DisplayChannel, @Message, SizeOf(Message), []);
end;

{ One message from the channel, without waiting. }
function ReceiveOne(out Message: TWindowMessage): Boolean;
var
  Handles: array[0..0] of Int64;
  Length: QWord;
  HandleCount: QWord;
  Error: LongInt;
begin
  repeat
    Result := False;
    Error := ReceiveMessage(DisplayChannel, @Message, SizeOf(Message), Length, Handles, HandleCount);
    if Error = ErrorWouldBlock then
      Exit;
    if Error <> ErrorNone then
    begin
      Broken := True;
      Exit;
    end;
    Result := Length = SizeOf(Message);
    if Result then
      Message.Reserved := 0;
    if HandleCount > 0 then
      if Result and KeepsHandle(Message.Kind) then
        Message.Reserved := StoreReceivedHandle(Handles[0])
      else
        CloseHandle(Handles[0]);
    { Answered here and now: the program may be waiting for something
      else, and whoever asked waits for this. }
    if Result and (Message.Kind = EventDataRender) and Assigned(DataRenderHandler) then
    begin
      DataRenderHandler(Message);
      Continue;
    end;
    Exit;
  until False;
end;

procedure Keep(const Message: TWindowMessage);
begin
  Insert(Message, Kept, Length(Kept));
end;

function NextEvent(out Message: TWindowMessage): Boolean;
begin
  if Length(Kept) > 0 then
  begin
    Message := Kept[0];
    Delete(Kept, 0, 1);
    Exit(True);
  end;
  if DisplayChannel < 0 then
    Exit(False);
  Result := ReceiveOne(Message);
end;

function WaitForEvent(Kind: LongWord; Timeout: Int64; out Message: TWindowMessage): Boolean;
begin
  Result := False;
  repeat
    while ReceiveOne(Message) do
    begin
      if Message.Kind = Kind then
        Exit(True);
      Keep(Message);
    end;
    if Broken then
      Exit;
  until WaitForHandle(DisplayChannel, Timeout) <> ErrorNone;
end;

function ConnectToDisplay(WaitForServer: Boolean): LongInt;
var
  Attempt: LongInt;
  AttemptCount: LongInt;
  Message: TWindowMessage;
begin
  if IsConnected then
    Exit(ErrorNone);
  Broken := False;
  Kept := nil;
  if WaitForServer then
    AttemptCount := ConnectAttempts
  else
    AttemptCount := 1;
  for Attempt := 1 to AttemptCount do
  begin
    DisplayChannel := ConnectPort(WindowingPortName);
    if (DisplayChannel >= 0) or (Attempt = AttemptCount) then
      Break;
    SleepMilliseconds(ConnectPause);
  end;
  if DisplayChannel < 0 then
  begin
    Result := LongInt(-DisplayChannel);
    DisplayChannel := -1;
    Exit;
  end;
  Message := NewMessage(RequestHello, 0);
  Message.Value := ProtocolVersion;
  SendRequest(Message, -1);
  if not WaitForEvent(EventWelcome, ReplyTimeout, Message) then
  begin
    DisconnectFromDisplay;
    Exit(ErrorTimedOut);
  end;
  TakeScaleChange(Message);
  UseScale(DefaultScale, DefaultDpi);
  { The theme the system's settings name, before anything is drawn. }
  ApplySystemTheme;
  Result := ErrorNone;
end;

procedure TakeScaleChange(const Message: TWindowMessage);
begin
  ScreenWidth := Message.Width;
  ScreenHeight := Message.Height;
  DefaultDpi := LongWord(Message.Value);
  DefaultScale := Message.Code;
end;

procedure UseScale(ScalePercent, Dpi: LongWord);
begin
  if ScalePercent = 0 then
    Exit;
  DisplayScale := ScalePercent;
  DisplayDpi := Dpi;
end;

procedure DisconnectFromDisplay;
begin
  if DisplayChannel >= 0 then
    CloseHandle(DisplayChannel);
  DisplayChannel := -1;
  Kept := nil;
end;

end.

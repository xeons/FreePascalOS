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
  answer tells the screen's size, DPI and scale, kept here for everyone
  (and the conversions between logical units and pixels). Messages are
  sent with SendRequest; WaitForEvent waits for one of a kind (a reply)
  and keeps whatever else arrives meanwhile for NextEvent, so nothing is
  lost or taken out of order. The scale can change while the program
  runs (EventScaleChanged; Windowing.Windows passes it here).
}
unit Windowing.Connection;

{$mode objfpc}

interface

uses
  Windowing.Protocol;

var
  DisplayChannel: Int64 = -1;
  ScreenWidth: LongInt;
  ScreenHeight: LongInt;
  DisplayDpi: LongWord = 96;
  DisplayScale: LongWord = 100;

{ ErrorNone, or an error code (no display server: ErrorNotFound). Waits a
  little for the server, as it may still be starting. }
function ConnectToDisplay: LongInt;
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
{ True once the server is gone. }
function ConnectionBroken: Boolean;
{ Takes the screen's size, DPI and scale from EventScaleChanged. }
procedure TakeScaleChange(const Message: TWindowMessage);

implementation

uses
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Processes;

const
  ConnectAttempts = 50;
  ConnectPause = 100;
  ReplyTimeout = 5000;
  MaximumKept = 256;

var
  Kept: array[0..MaximumKept - 1] of TWindowMessage;
  KeptCount: LongInt;
  Broken: Boolean;

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
  Result := False;
  Error := ReceiveMessage(DisplayChannel, @Message, SizeOf(Message), Length, Handles, HandleCount);
  if Error = ErrorWouldBlock then
    Exit;
  if Error <> ErrorNone then
  begin
    Broken := True;
    Exit;
  end;
  if HandleCount > 0 then
    CloseHandle(Handles[0]);
  Result := Length = SizeOf(Message);
end;

procedure Keep(const Message: TWindowMessage);
begin
  if KeptCount < MaximumKept then
  begin
    Kept[KeptCount] := Message;
    Inc(KeptCount);
  end;
end;

function NextEvent(out Message: TWindowMessage): Boolean;
var
  Index: LongInt;
begin
  if KeptCount > 0 then
  begin
    Message := Kept[0];
    for Index := 1 to KeptCount - 1 do
      Kept[Index - 1] := Kept[Index];
    Dec(KeptCount);
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

function ConnectToDisplay: LongInt;
var
  Attempt: LongInt;
  Message: TWindowMessage;
begin
  if IsConnected then
    Exit(ErrorNone);
  Broken := False;
  KeptCount := 0;
  for Attempt := 1 to ConnectAttempts do
  begin
    DisplayChannel := ConnectPort(WindowingPortName);
    if DisplayChannel >= 0 then
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
  ScreenWidth := Message.Width;
  ScreenHeight := Message.Height;
  DisplayDpi := LongWord(Message.Value);
  DisplayScale := Message.Code;
  Result := ErrorNone;
end;

procedure TakeScaleChange(const Message: TWindowMessage);
begin
  ScreenWidth := Message.Width;
  ScreenHeight := Message.Height;
  DisplayDpi := LongWord(Message.Value);
  DisplayScale := Message.Code;
end;

procedure DisconnectFromDisplay;
begin
  if DisplayChannel >= 0 then
    CloseHandle(DisplayChannel);
  DisplayChannel := -1;
  KeptCount := 0;
end;

end.

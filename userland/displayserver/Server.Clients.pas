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
  The programs connected to the server, and what they ask of it.

  Each is a channel accepted at the port. ServeClient takes every
  message waiting on its channel and carries it out; when the channel
  breaks (the program ended) its windows go. Events for a program are
  sent without waiting: if its queue is full (it stopped reading) they
  are dropped rather than holding up everyone else.
}
unit Server.Clients;

{$mode objfpc}

interface

uses
  Windowing.Protocol;

const
  { Wait handles: the input device and the port take two of 64. }
  MaximumClients = 62;

type
  PClient = ^TClient;
  TClient = record
    Channel: Int64;
  end;

var
  Clients: array[0..MaximumClients - 1] of PClient;
  ClientCount: LongInt;

procedure AcceptClients(Port: Int64);
procedure ServeClient(Client: PClient);
procedure SendToClient(Client: PClient; var Message: TWindowMessage);

implementation

uses
  Abi.SystemCalls,
  Sys.Objects,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Server.Theme,
  Server.Screen,
  Server.Windows,
  Server.Composer,
  Server.Actions,
  Server.Input;

procedure SendToClient(Client: PClient; var Message: TWindowMessage);
begin
  if Client <> nil then
    SendMessage(Client^.Channel, @Message, SizeOf(Message), []);
end;

procedure AcceptClients(Port: Int64);
var
  Channel: Int64;
  Client: PClient;
begin
  repeat
    Channel := AcceptConnection(Port);
    if Channel < 0 then
      Exit;
    if ClientCount = MaximumClients then
    begin
      CloseHandle(Channel);
      Continue;
    end;
    New(Client);
    Client^.Channel := Channel;
    Clients[ClientCount] := Client;
    Inc(ClientCount);
  until False;
end;

procedure DisconnectClient(Client: PClient);
var
  Index: LongInt;
begin
  for Index := WindowCount - 1 downto 0 do
    if (Index < WindowCount) and (Windows[Index]^.Owner = Client) then
      DestroyWindow(Windows[Index]);
  CloseHandle(Client^.Channel);
  for Index := 0 to ClientCount - 1 do
    if Clients[Index] = Client then
    begin
      Clients[Index] := Clients[ClientCount - 1];
      Dec(ClientCount);
      Break;
    end;
  Dispose(Client);
end;

{ Maps Section as the window's surface (Width x Height pixels). }
function TakeSurface(Window: PServerWindow; Section: Int64; Width, Height: LongInt): Boolean;
var
  Pixels: Pointer;
begin
  Result := False;
  if (Width <= 0) or (Height <= 0) or (Width > 16384) or (Height > 16384) then
    Exit;
  Pixels := MapSection(Section, 0, QWord(Width) * QWord(Height) * 4);
  if Pixels = nil then
    Exit;
  ReleaseSurface(Window);
  Window^.Section := Section;
  Window^.Surface := SurfaceOnPixels(Pixels, Width, Height, Width * 4);
  Result := True;
end;

{ The window Message names, if it is this client's. }
function OwnWindow(Client: PClient; const Message: TWindowMessage): PServerWindow;
begin
  Result := FindWindow(Message.Window);
  if (Result <> nil) and (Result^.Owner <> Client) then
    Result := nil;
end;

procedure CreateWindowFor(Client: PClient; var Message: TWindowMessage; Section: Int64);
var
  Window: PServerWindow;
  Reply: TWindowMessage;
begin
  Window := AddWindow(Client, Message.Flags);
  if Window = nil then
  begin
    CloseHandle(Section);
    Exit;
  end;
  if not TakeSurface(Window, Section, Message.SurfaceWidth, Message.SurfaceHeight) then
  begin
    CloseHandle(Section);
    RemoveWindow(Window);
    Exit;
  end;
  Window^.ClientLeft := LogicalToPixels(Message.Left, ScalePercent);
  Window^.ClientTop := LogicalToPixels(Message.Top, ScalePercent);
  Message.Text[TitleCapacity - 1] := #0;
  Move(Message.Text, Window^.Title, SizeOf(Window^.Title));
  Reply := NewMessage(EventWindowCreated, Window^.Id);
  SendToClient(Client, Reply);
end;

procedure CarryOut(Client: PClient; var Message: TWindowMessage; Handle: Int64);
var
  Window: PServerWindow;
  Reply: TWindowMessage;
  Changed: TRectangle;
begin
  if Message.Kind = RequestHello then
  begin
    if Handle >= 0 then
      CloseHandle(Handle);
    Reply := NewMessage(EventWelcome, 0);
    Reply.Width := Display.Width;
    Reply.Height := Display.Height;
    Reply.Value := Dpi;
    Reply.Code := ScalePercent;
    SendToClient(Client, Reply);
    Exit;
  end;
  if Message.Kind = RequestCreateWindow then
  begin
    if Handle < 0 then
      Exit;
    CreateWindowFor(Client, Message, Handle);
    Exit;
  end;
  Window := OwnWindow(Client, Message);
  if Window = nil then
  begin
    if Handle >= 0 then
      CloseHandle(Handle);
    Exit;
  end;
  case Message.Kind of
    RequestDestroyWindow:
      DestroyWindow(Window);
    RequestShowWindow:
      ShowWindow(Window, Message.Value <> 0);
    RequestMoveWindow:
      MoveWindowTo(Window, LogicalToPixels(Message.Left, ScalePercent), LogicalToPixels(Message.Top, ScalePercent));
    RequestSetTitle:
      begin
        Message.Text[TitleCapacity - 1] := #0;
        Move(Message.Text, Window^.Title, SizeOf(Window^.Title));
        if Window^.Visible then
          DamageWindow(Window);
      end;
    RequestSetSurface:
      if Handle >= 0 then
      begin
        if Window^.Visible then
          DamageWindow(Window);
        if not TakeSurface(Window, Handle, Message.SurfaceWidth, Message.SurfaceHeight) then
          CloseHandle(Handle);
        if Window^.Visible then
          DamageWindow(Window);
      end;
    RequestDamage:
      if Window^.Visible and IntersectRectangles(MakeRectangle(Window^.ClientLeft + Message.Left,
         Window^.ClientTop + Message.Top, Message.Width, Message.Height), ClientRectangle(Window), Changed) then
        AddDamage(Changed);
    RequestActivate:
      ActivateWindow(Window);
    RequestSetCapture:
      SetPointerCapture(Window, Message.Value <> 0);
  end;
end;

procedure ServeClient(Client: PClient);
var
  Message: TWindowMessage;
  Handles: array[0..0] of Int64;
  Length: QWord;
  HandleCount: QWord;
  Error: LongInt;
begin
  repeat
    Handles[0] := -1;
    Error := ReceiveMessage(Client^.Channel, @Message, SizeOf(Message), Length, Handles, HandleCount);
    if Error = ErrorWouldBlock then
      Exit;
    if Error <> ErrorNone then
    begin
      DisconnectClient(Client);
      Exit;
    end;
    if HandleCount = 0 then
      Handles[0] := -1;
    if Length = SizeOf(Message) then
      CarryOut(Client, Message, Handles[0])
    else if Handles[0] >= 0 then
      CloseHandle(Handles[0]);
  until False;
end;

end.

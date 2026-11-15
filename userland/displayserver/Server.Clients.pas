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

  Besides their windows, programs ask about the displays (each one's
  place, size, scale, modes and work area) and change a display's scale
  or mode; places they give and are told are logical units of the
  desktop (Server.Desktop). One of them may be the shell
  (Server.Shell), which alone sets work areas and manages other
  programs' windows; any program may put icons in its notification area
  (Server.Notifications).
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
  Windowing.Theme,
  Abi.SystemCalls,
  Sys.Objects,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Sys.Display,
  Server.Screen,
  Server.Desktop,
  Server.Windows,
  Server.Composer,
  Server.Actions,
  Server.Input,
  Server.Scale,
  Server.Modes,
  Server.MouseSettings,
  Server.PointerAreas,
  Server.WorkAreas,
  Server.WindowStates,
  Server.Shell,
  Server.Notifications;

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
    if (Index < WindowCount) and (Windows[Index]^.Client = Client) then
      DestroyWindow(Windows[Index]);
  ForgetClientNotificationIcons(Client);
  ForgetClientInShell(Client);
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

{ Window number Id, if it is this client's. }
function OwnWindowNumbered(Client: PClient; Id: LongWord): PServerWindow;
begin
  Result := FindWindow(Id);
  if (Result <> nil) and (Result^.Client <> Client) then
    Result := nil;
end;

{ The window Message names, if it is this client's. }
function OwnWindow(Client: PClient; const Message: TWindowMessage): PServerWindow;
begin
  Result := OwnWindowNumbered(Client, Message.Window);
end;

procedure CreateWindowFor(Client: PClient; var Message: TWindowMessage; Section: Int64);
var
  Window: PServerWindow;
  OwnerWindow: PServerWindow;
  Reply: TWindowMessage;
begin
  { Only a window of the same program can own it. }
  OwnerWindow := OwnWindowNumbered(Client, Message.Code);
  Window := AddWindow(Client, Message.Flags, OwnerWindow);
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
  LogicalToDesktop(Message.Left, Message.Top, Window^.ClientLeft, Window^.ClientTop);
  Message.Text[TitleCapacity - 1] := #0;
  Move(Message.Text, Window^.Title, SizeOf(Window^.Title));
  Reply := NewMessage(EventWindowCreated, Window^.Id);
  SendToClient(Client, Reply);
  { The program drew it at display 0's scale (what it was welcomed with);
    on another display it is told that one's. Then it is kept out of the
    shell's taskbar. }
  Window^.ScreenNumber := 0;
  SettleWindowOnScreen(Window);
  PlaceWindowInWorkArea(Window);
  SettleWindowOnScreen(Window);
end;

procedure DescribeScreen(Client: PClient; Number: LongInt);
var
  Reply: TWindowMessage;
  Screen: PScreen;
begin
  Reply := NewMessage(EventDisplayDescribed, 0);
  Screen := ScreenByNumber(Number);
  if Screen <> nil then
  begin
    Reply.Flags := DisplayExists;
    Reply.Width := Screen^.Device.Width;
    Reply.Height := Screen^.Device.Height;
    Reply.Value := Screen^.Dpi;
    Reply.Code := Screen^.ScalePercent;
    Reply.Left := Screen^.LogicalBounds.Left;
    Reply.Top := Screen^.LogicalBounds.Top;
    Reply.SurfaceWidth := RectangleWidth(Screen^.LogicalBounds);
    Reply.SurfaceHeight := RectangleHeight(Screen^.LogicalBounds);
  end;
  SendToClient(Client, Reply);
end;

procedure DescribeScreenMode(Client: PClient; Number, Index: LongInt);
var
  Reply: TWindowMessage;
  Screen: PScreen;
  Width: LongWord;
  Height: LongWord;
begin
  Reply := NewMessage(EventDisplayMode, 0);
  Screen := ScreenByNumber(Number);
  if (Screen <> nil) and DisplayModeAt(Screen^.Device, Index, Width, Height) then
  begin
    Reply.Width := Width;
    Reply.Height := Height;
    if (Width = Screen^.Device.Width) and (Height = Screen^.Device.Height) then
      Reply.Flags := DisplayModeCurrent;
  end;
  SendToClient(Client, Reply);
end;

procedure DescribeWorkArea(Client: PClient; Number: LongInt);
var
  Reply: TWindowMessage;
  Screen: PScreen;
  Area: TRectangle;
begin
  Reply := NewMessage(EventWorkArea, 0);
  Reply.Code := LongWord(Number);
  Screen := ScreenByNumber(Number);
  if Screen <> nil then
  begin
    Area := LogicalWorkArea(Screen);
    Reply.Flags := DisplayExists;
    Reply.Left := Area.Left;
    Reply.Top := Area.Top;
    Reply.Width := RectangleWidth(Area);
    Reply.Height := RectangleHeight(Area);
  end;
  SendToClient(Client, Reply);
end;

procedure AnswerShellRegistration(Client: PClient);
var
  Reply: TWindowMessage;
begin
  Reply := NewMessage(EventShellRegistered, 0);
  Reply.Value := Ord(RegisterShell(Client));
  SendToClient(Client, Reply);
  { Its windows' list follows from the server's loop (Server.Shell);
    the icons there are already are told now. }
  if Reply.Value <> 0 then
    TellShellAllNotificationIcons;
end;

procedure SendWelcome(Client: PClient);
var
  Reply: TWindowMessage;
begin
  Reply := NewMessage(EventWelcome, 0);
  Reply.Width := Screens[0].Device.Width;
  Reply.Height := Screens[0].Device.Height;
  Reply.Value := Screens[0].Dpi;
  Reply.Code := Screens[0].ScalePercent;
  SendToClient(Client, Reply);
end;

procedure SendMouseSettings(Client: PClient);
var
  Reply: TWindowMessage;
begin
  Reply := NewMessage(EventMouseSettings, 0);
  Reply.Code := MouseSpeed;
  Reply.Value := MouseAcceleration;
  if LeftHandedButtons then
    Reply.Flags := MouseLeftHanded;
  SendToClient(Client, Reply);
end;

{ The requests about no window in particular (Window 0): the greeting,
  the displays, the mouse's settings, the shell and notification icons;
  False if Message is not one. }
function CarryOutDisplayRequest(Client: PClient; var Message: TWindowMessage): Boolean;
var
  Screen: PScreen;
begin
  Result := True;
  case Message.Kind of
    RequestHello:
      SendWelcome(Client);
    RequestSetScale:
      begin
        Screen := ScreenByNumber(Message.Value);
        if Screen <> nil then
          ChangeScale(Screen, Message.Code);
        DescribeScreen(Client, Message.Value);
      end;
    RequestDescribeDisplay:
      DescribeScreen(Client, LongInt(Message.Code));
    RequestSetDisplayMode:
      begin
        Screen := ScreenByNumber(LongInt(Message.Code));
        if Screen <> nil then
          ChangeMode(Screen, Message.Width, Message.Height);
        DescribeScreen(Client, LongInt(Message.Code));
      end;
    RequestDescribeDisplayMode:
      DescribeScreenMode(Client, LongInt(Message.Code), Message.Value);
    RequestGetMouseSettings:
      SendMouseSettings(Client);
    RequestSetMouseSettings:
      begin
        ChangeMouseSettings(Message.Code, LongWord(Message.Value),
          (Message.Flags and MouseLeftHanded) <> 0);
        SendMouseSettings(Client);
      end;
    RequestRegisterShell:
      AnswerShellRegistration(Client);
    RequestSetWorkArea:
      begin
        Screen := ScreenByNumber(LongInt(Message.Code));
        if (Screen <> nil) and IsShell(Client) then
          SetWorkArea(Screen, MakeRectangle(Message.Left, Message.Top, Message.Width, Message.Height));
      end;
    RequestDescribeWorkArea:
      DescribeWorkArea(Client, LongInt(Message.Code));
    RequestSetNotificationIcon:
      begin
        Message.Text[TitleCapacity - 1] := #0;
        SetNotificationIcon(Client, Message.Code, Message.Value <> 0, Message.Flags, @Message.Text[0]);
      end;
  else
    Result := False;
  end;
end;

procedure CarryOut(Client: PClient; var Message: TWindowMessage; Handle: Int64);
var
  Window: PServerWindow;
  Changed: TRectangle;
  Left: LongInt;
  Top: LongInt;
begin
  if CarryOutDisplayRequest(Client, Message) then
  begin
    if Handle >= 0 then
      CloseHandle(Handle);
    Exit;
  end;
  if Message.Kind = RequestCreateWindow then
  begin
    if Handle < 0 then
      Exit;
    CreateWindowFor(Client, Message, Handle);
    Exit;
  end;
  if Message.Kind = RequestManageWindow then
  begin
    if Handle >= 0 then
      CloseHandle(Handle);
    { The shell manages any window; a program its own. }
    Window := FindWindow(Message.Window);
    if (Window <> nil) and ((Window^.Client = Pointer(Client)) or IsShell(Client)) then
      ManageWindow(Window, Message.Code);
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
      begin
        LogicalToDesktop(Message.Left, Message.Top, Left, Top);
        MoveWindowTo(Window, Left, Top);
        SettleWindowOnScreen(Window);
      end;
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
    RequestEnableWindow:
      EnableWindow(Window, Message.Value <> 0);
    RequestSetOwner:
      { A window that is not this program's cannot own it: refused. }
      if (Message.Code = 0) or (OwnWindowNumbered(Client, Message.Code) <> nil) then
        SetWindowOwner(Window, OwnWindowNumbered(Client, Message.Code));
    RequestSetPointerShape:
      SetPointerArea(Window, LongWord(Message.Value), MakeRectangle(Message.Left, Message.Top, Message.Width,
        Message.Height), Message.Code);
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

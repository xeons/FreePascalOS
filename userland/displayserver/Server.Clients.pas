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
  (Server.Shell), which alone sets work areas and takes keys for the
  whole desktop (Server.Hotkeys); any program may put icons in its
  notification area (Server.Notifications) and list the other programs'
  windows (Server.WindowList). Who each program is - its process and
  the user it runs as - is asked of the kernel when it connects, and
  decides whose windows it may see and manage.
}
unit Server.Clients;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Protocol;

const
  { Wait handles: the input device and the port take two of 64. }
  MaximumClients = 62;

type
  { A connected program. }
  TClient = class
  public
    Channel: Int64;
    { The program at the other end, and its effective user when it
      connected. }
    ProcessId: QWord;
    UserId: LongWord;
    { Whether it answers pings (Server.Responsiveness), the one it was
      sent last, when, whether it is still unanswered, and whether the
      program has stopped responding. }
    AnswersPings: Boolean;
    PingNumber: LongInt;
    PingSentAt: QWord;
    PingOutstanding: Boolean;
    NotResponding: Boolean;
    constructor Create(ClientChannel: Int64; ClientProcessId: QWord; ClientUserId: LongWord);
  end;

var
  { Every connected program. }
  Clients: array of TClient;

function ClientCount: LongInt;

procedure AcceptClients(Port: Int64);
procedure ServeClient(Client: TClient);
procedure SendToClient(Client: TClient; var Message: TWindowMessage);

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
  Server.KeyboardSettings,
  Sys.Keyboard,
  Server.RememberedSettings,
  Server.PointerAreas,
  Server.WorkAreas,
  Server.WindowStates,
  Server.Shell,
  Server.Hotkeys,
  Server.WindowList,
  Server.Notifications,
  Server.DataOffers,
  Server.WindowIcons,
  Server.ScreenLock,
  Server.Responsiveness;

constructor TClient.Create(ClientChannel: Int64; ClientProcessId: QWord; ClientUserId: LongWord);
begin
  inherited Create;
  Channel := ClientChannel;
  ProcessId := ClientProcessId;
  UserId := ClientUserId;
end;

function ClientCount: LongInt;
begin
  Result := Length(Clients);
end;

procedure SendToClient(Client: TClient; var Message: TWindowMessage);
begin
  if Client <> nil then
    SendMessage(Client.Channel, @Message, SizeOf(Message), []);
end;

procedure AcceptClients(Port: Int64);
var
  Channel: Int64;
  Peer: TAbiChannelPeer;
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
    { A program the kernel cannot name is let in as nobody in particular:
      it sees and manages only its own windows. }
    if GetChannelPeer(Channel, Peer) <> ErrorNone then
    begin
      Peer.ProcessId := 0;
      Peer.UserId := High(LongWord);
    end;
    Insert(TClient.Create(Channel, Peer.ProcessId, Peer.UserId), Clients, Length(Clients));
  until False;
end;

procedure DisconnectClient(Client: TClient);
var
  Index: LongInt;
begin
  for Index := WindowCount - 1 downto 0 do
    if (Index < WindowCount) and (Windows[Index].Client = Client) then
      DestroyWindow(Windows[Index]);
  ForgetClientNotificationIcons(Client);
  ForgetClientData(Client);
  if IsShell(Client) then
    ForgetHotkeys;
  ForgetClientInShell(Client);
  ForgetClientInLock(Client);
  CloseHandle(Client.Channel);
  { The last client takes its place, as it always has. }
  for Index := 0 to High(Clients) do
    if Clients[Index] = Client then
    begin
      Clients[Index] := Clients[High(Clients)];
      SetLength(Clients, Length(Clients) - 1);
      Break;
    end;
  Client.Free;
end;

{ Maps Section as the window's surface (Width x Height pixels). }
function TakeSurface(Window: TServerWindow; Section: Int64; Width, Height: LongInt): Boolean;
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
  Window.Section := Section;
  Window.Surface := SurfaceOnPixels(Pixels, Width, Height, Width * 4);
  Result := True;
end;

{ Window number Id, if it is this client's. }
function OwnWindowNumbered(Client: TClient; Id: LongWord): TServerWindow;
begin
  Result := FindWindow(Id);
  if (Result <> nil) and (Result.Client <> Client) then
    Result := nil;
end;

{ The window Message names, if it is this client's. }
function OwnWindow(Client: TClient; const Message: TWindowMessage): TServerWindow;
begin
  Result := OwnWindowNumbered(Client, Message.Window);
end;

procedure CreateWindowFor(Client: TClient; var Message: TWindowMessage; Section: Int64);
var
  Window: TServerWindow;
  OwnerWindow: TServerWindow;
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
  LogicalToDesktop(Message.Left, Message.Top, Window.ClientLeft, Window.ClientTop);
  Window.Title := MessageText(Message);
  Reply := NewMessage(EventWindowCreated, Window.Id);
  SendToClient(Client, Reply);
  { The program drew it at display 0's scale (what it was welcomed with);
    on another display it is told that one's. Then it is kept out of the
    shell's taskbar. }
  Window.ScreenNumber := 0;
  SettleWindowOnScreen(Window);
  PlaceWindowInWorkArea(Window);
  SettleWindowOnScreen(Window);
end;

procedure DescribeScreen(Client: TClient; Number: LongInt);
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

procedure DescribeScreenMode(Client: TClient; Number, Index: LongInt);
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

procedure DescribeWorkArea(Client: TClient; Number: LongInt);
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

procedure AnswerShellRegistration(Client: TClient);
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

procedure SendWelcome(Client: TClient);
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

procedure SendMouseSettings(Client: TClient);
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

procedure SendKeyboardSettings(Client: TClient);
var
  Reply: TWindowMessage;
  Settings: TKeyboardSettings;
begin
  Settings := CurrentKeyboardSettings;
  Reply := NewMessage(EventKeyboardSettings, 0);
  SetMessageText(Reply, Settings.Layout);
  Reply.Code := Settings.RepeatDelay;
  Reply.Value := LongInt(Settings.RepeatRate);
  SendToClient(Client, Reply);
end;

procedure TakeKeyboardSettings(const Message: TWindowMessage);
var
  Settings: TKeyboardSettings;
begin
  Settings := NewKeyboardSettings(MessageText(Message));
  Settings.RepeatDelay := Message.Code;
  Settings.RepeatRate := LongWord(Message.Value);
  ChangeKeyboardSettings(Settings);
end;

{ The requests about no window in particular (Window 0): the greeting,
  the displays, the mouse's and keyboards' settings, the shell and
  notification icons;
  False if Message is not one. }
function CarryOutDisplayRequest(Client: TClient; var Message: TWindowMessage): Boolean;
var
  Screen: PScreen;
begin
  Result := True;
  case Message.Kind of
    RequestHello:
      begin
        Client.AnswersPings := (Message.Flags and HelloAnswersPings) <> 0;
        SendWelcome(Client);
      end;
    RequestAnswerPing:
      NoteAnswerToPing(Client, Message.Value);
    RequestSetScale:
      begin
        Screen := ScreenByNumber(Message.Value);
        if Screen <> nil then
        begin
          ChangeScale(Screen, Message.Code);
          if (Message.Flags and DisplayRemember) <> 0 then
            RememberScreenScale(Screen);
        end;
        DescribeScreen(Client, Message.Value);
      end;
    RequestDescribeDisplay:
      DescribeScreen(Client, LongInt(Message.Code));
    RequestSetDisplayMode:
      begin
        Screen := ScreenByNumber(LongInt(Message.Code));
        if (Screen <> nil) and (ChangeMode(Screen, Message.Width, Message.Height) = ErrorNone) and
           ((Message.Flags and DisplayRemember) <> 0) then
          RememberScreenMode(Screen);
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
    RequestGetKeyboardSettings:
      SendKeyboardSettings(Client);
    RequestSetKeyboardSettings:
      begin
        TakeKeyboardSettings(Message);
        SendKeyboardSettings(Client);
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
      SetNotificationIcon(Client, Message.Code, Message.Value <> 0, Message.Flags, MessageText(Message));
    RequestListWindows:
      ListWindowsFor(Client);
    RequestRegisterHotkey:
      if IsShell(Client) then
        SetHotkey(Message.Code, Message.Modifiers, Message.Value <> 0);
  else
    Result := False;
  end;
end;

procedure CarryOut(Client: TClient; var Message: TWindowMessage; Handle: Int64);
var
  Window: TServerWindow;
  Changed: TRectangle;
  Left: LongInt;
  Top: LongInt;
begin
  { The clipboard and drags (Server.DataOffers): sections come with them. }
  if CarryOutDataRequest(Client, Message, Handle) then
    Exit;
  { Window icons (Server.WindowIcons): pictures come in sections. }
  if CarryOutIconRequest(Client, Message, Handle) then
    Exit;
  if CarryOutDisplayRequest(Client, Message) or CarryOutLockRequest(Client, Message) then
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
    Window := FindWindow(Message.Window);
    if (Window <> nil) and MayManageWindow(Client, Window) then
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
        Window.Title := MessageText(Message);
        if Window.Visible then
          DamageWindow(Window);
      end;
    RequestSetSurface:
      if Handle >= 0 then
      begin
        if Window.Visible then
          DamageWindow(Window);
        if not TakeSurface(Window, Handle, Message.SurfaceWidth, Message.SurfaceHeight) then
          CloseHandle(Handle);
        if Window.Visible then
          DamageWindow(Window);
      end;
    RequestDamage:
      if Window.Visible and IntersectRectangles(MakeRectangle(Window.ClientLeft + Message.Left,
         Window.ClientTop + Message.Top, Message.Width, Message.Height), ClientRectangle(Window), Changed) then
        AddDamage(Changed);
    RequestActivate:
      ActivateWindow(Window);
    RequestSetCapture:
      SetPointerCapture(Window, Message.Value <> 0);
    RequestSetPointerLock:
      SetPointerLock(Window, Message.Value <> 0);
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

procedure ServeClient(Client: TClient);
var
  Message: TWindowMessage;
  Handles: array[0..0] of Int64;
  Length: QWord;
  HandleCount: QWord;
  Error: LongInt;
begin
  repeat
    Handles[0] := -1;
    Error := ReceiveMessage(Client.Channel, @Message, SizeOf(Message), Length, Handles, HandleCount);
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

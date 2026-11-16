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
  Notification icons: small pictures with a tooltip that programs put in
  the shell's notification area (a volume control, the network).

  The server only keeps them and passes them on: each icon is known to
  its program by a number it picked, and to the shell by one the server
  gives (programs' numbers may clash). They are kept while no shell runs,
  so a shell that starts later still shows them, and they go when their
  program ends. What an icon shows is one of the pictures the shell
  draws (NotificationPicture*): programs send no pixels.
}
unit Server.Notifications;

{$mode objfpc}
{$H+}

interface

uses
  Server.Clients;

{ Shows (Show) or takes away the icon Client numbers Code, with Picture
  and Tooltip. }
procedure SetNotificationIcon(Client: TClient; Code: LongWord; Show: Boolean; Picture: LongWord;
  const Tooltip: string);
{ Client is going: so are its icons. }
procedure ForgetClientNotificationIcons(Client: TClient);
{ Tells the shell (just registered) about every icon there is. }
procedure TellShellAllNotificationIcons;

implementation

uses
  Windowing.Protocol,
  Server.Shell;

const
  MaximumIcons = 64;

type
  TNotificationIcon = record
    { The server's number for it, which the shell knows it by. }
    Number: LongWord;
    Client: TClient;
    { The program's number for it. }
    Code: LongWord;
    Picture: LongWord;
    Tooltip: string;
  end;

var
  Icons: array of TNotificationIcon;
  NextNumber: LongWord = 1;

function IndexOfIcon(Client: TClient; Code: LongWord): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Icons) do
    if (Icons[Index].Client = Client) and (Icons[Index].Code = Code) then
      Exit(Index);
  Result := -1;
end;

procedure TellShell(const Icon: TNotificationIcon; Shown: Boolean);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(EventNotificationIconChanged, 0);
  Message.Code := Icon.Number;
  Message.Value := Ord(Shown);
  Message.Flags := Icon.Picture;
  SetMessageText(Message, PChar(Icon.Tooltip));
  SendToShell(Message);
end;

{ The last icon takes its place, as it always has. }
procedure RemoveIcon(Index: LongInt);
begin
  TellShell(Icons[Index], False);
  Icons[Index] := Icons[High(Icons)];
  SetLength(Icons, Length(Icons) - 1);
end;

procedure SetNotificationIcon(Client: TClient; Code: LongWord; Show: Boolean; Picture: LongWord;
  const Tooltip: string);
var
  Index: LongInt;
begin
  Index := IndexOfIcon(Client, Code);
  if not Show then
  begin
    if Index >= 0 then
      RemoveIcon(Index);
    Exit;
  end;
  if Index < 0 then
  begin
    if Length(Icons) = MaximumIcons then
      Exit;
    Index := Length(Icons);
    SetLength(Icons, Index + 1);
    Icons[Index].Number := NextNumber;
    Inc(NextNumber);
    Icons[Index].Client := Client;
    Icons[Index].Code := Code;
  end;
  Icons[Index].Picture := Picture;
  { Cut short to fit a message's text, as the shell will hear it. }
  Icons[Index].Tooltip := Copy(Tooltip, 1, TitleCapacity - 1);
  TellShell(Icons[Index], True);
end;

procedure ForgetClientNotificationIcons(Client: TClient);
var
  Index: LongInt;
begin
  for Index := High(Icons) downto 0 do
    if Icons[Index].Client = Client then
      RemoveIcon(Index);
end;

procedure TellShellAllNotificationIcons;
var
  Index: LongInt;
begin
  for Index := 0 to High(Icons) do
    TellShell(Icons[Index], True);
end;

end.

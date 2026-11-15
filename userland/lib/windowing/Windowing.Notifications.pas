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
  Icons in the shell's notification area, for any program: a small
  picture (one the shell draws: NotificationPicture* in
  Windowing.Protocol) with a tooltip. A program numbers its icons as it
  likes; showing one again with the same number changes it. They go
  when the program ends. The display server keeps them for the shell,
  so they may be shown before a shell runs.
}
unit Windowing.Notifications;

{$mode objfpc}

interface

{ Shows (or changes) this program's icon Number: Picture with Tooltip.
  The program must be connected (ConnectToDisplay). }
procedure ShowNotificationIcon(Number: LongWord; Picture: LongWord; Tooltip: PChar);
procedure RemoveNotificationIcon(Number: LongWord);

implementation

uses
  Windowing.Protocol,
  Windowing.Connection;

procedure ShowNotificationIcon(Number: LongWord; Picture: LongWord; Tooltip: PChar);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(RequestSetNotificationIcon, 0);
  Message.Code := Number;
  Message.Value := 1;
  Message.Flags := Picture;
  SetMessageText(Message, Tooltip);
  SendRequest(Message, -1);
end;

procedure RemoveNotificationIcon(Number: LongWord);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(RequestSetNotificationIcon, 0);
  Message.Code := Number;
  SendRequest(Message, -1);
end;

end.

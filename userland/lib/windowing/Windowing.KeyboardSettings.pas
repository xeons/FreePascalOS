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
  The keyboards' settings on the screen: the layout and the key repeat,
  asked of the display server, changed there, and kept in the settings
  (libconfiguration).

  Keys become characters in the kernel (one set of layout tables for the
  console and the display server, Sys.Keyboard), and changing them is
  root's; the display server, which runs as root, changes them for any
  program at the screen, as it does the mouse's settings. They are the
  user's: the group Keyboard of their settings (Layout, RepeatDelay,
  RepeatRate), over the system's (what the login window has), over the
  machine's own (the layout the kernel option keymap= chose at boot,
  else US, and the kernel's repeat). The session manager gives the
  server a user's settings when they log in and the system's when they
  log off; a program that changes them for the user (keyboardsettings
  --remember, the Control Panel) keeps them in the user's settings.

  The calls that talk to the server wait for its answer (other events
  are kept, Windowing.Connection); the program must be connected.
}
unit Windowing.KeyboardSettings;

{$mode objfpc}
{$H+}

interface

uses
  Sys.Keyboard,
  Configuration.Settings;

const
  KeyboardLayoutSetting = 'Keyboard/Layout';
  KeyRepeatDelaySetting = 'Keyboard/RepeatDelay';
  KeyRepeatRateSetting = 'Keyboard/RepeatRate';

{ What the server (the kernel) has now; False if it did not answer. }
function AskKeyboardSettings(out Settings: TKeyboardSettings): Boolean;
{ Gives the server new settings; Applied is what it has then (the old
  layout if the kernel has no such one). }
function ChangeKeyboardSettings(const Settings: TKeyboardSettings; out Applied: TKeyboardSettings): Boolean;

{ The settings Store holds (each one missing, or out of its range, is
  the machine's own). }
function RememberedKeyboardSettings(Store: TSettings): TKeyboardSettings;
{ Keeps Settings in one of Store's scopes (flushed by the caller). }
procedure RememberKeyboardSettings(Store: TSettings; const Settings: TKeyboardSettings;
  Scope: TSettingsScopeKind = ScopeUser);
{ The machine's own: the boot's layout (keymap=, else us) and the
  kernel's default repeat. }
function DefaultKeyboardSettings: TKeyboardSettings;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.KernelOptions,
  Windowing.Protocol,
  Windowing.Connection;

const
  ReplyTimeout = 5000;
  BootLayoutOption = 'keymap';

function SettingsFromEvent(const Event: TWindowMessage): TKeyboardSettings;
begin
  Result := NewKeyboardSettings(@Event.Text[0]);
  Result.RepeatDelay := Event.Code;
  Result.RepeatRate := LongWord(Event.Value);
end;

function AskKeyboardSettings(out Settings: TKeyboardSettings): Boolean;
var
  Request: TWindowMessage;
  Reply: TWindowMessage;
begin
  Settings := DefaultKeyboardSettings;
  Request := NewMessage(RequestGetKeyboardSettings, 0);
  SendRequest(Request, -1);
  Result := WaitForEvent(EventKeyboardSettings, ReplyTimeout, Reply);
  if Result then
    Settings := SettingsFromEvent(Reply);
end;

function ChangeKeyboardSettings(const Settings: TKeyboardSettings; out Applied: TKeyboardSettings): Boolean;
var
  Request: TWindowMessage;
  Reply: TWindowMessage;
begin
  Applied := Settings;
  Request := NewMessage(RequestSetKeyboardSettings, 0);
  SetMessageText(Request, @Settings.Layout[0]);
  Request.Code := Settings.RepeatDelay;
  Request.Value := LongInt(Settings.RepeatRate);
  SendRequest(Request, -1);
  Result := WaitForEvent(EventKeyboardSettings, ReplyTimeout, Reply);
  if Result then
    Applied := SettingsFromEvent(Reply);
end;

function IsKnownLayout(const Name: string): Boolean;
var
  Index: Integer;
  Layout: TKeyboardLayoutDescription;
begin
  Index := 0;
  while DescribeKeyboardLayout(Index, Layout) do
  begin
    if string(PChar(@Layout.Name[0])) = Name then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

function DefaultKeyboardSettings: TKeyboardSettings;
var
  BootLayout: array[0..KeyboardLayoutNameCapacity - 1] of Char;
begin
  Result := NewKeyboardSettings(DefaultKeyboardLayout);
  if GetKernelOption(BootLayoutOption, @BootLayout[0], KeyboardLayoutNameCapacity) and
     IsKnownLayout(PChar(@BootLayout[0])) then
    CopyText(@Result.Layout[0], @BootLayout[0], KeyboardLayoutNameCapacity);
end;

function RememberedKeyboardSettings(Store: TSettings): TKeyboardSettings;
var
  Layout: string;
begin
  Result := DefaultKeyboardSettings;
  Layout := Store.ReadString(KeyboardLayoutSetting, '');
  if (Layout <> '') and IsKnownLayout(Layout) then
    CopyText(@Result.Layout[0], PChar(Layout), KeyboardLayoutNameCapacity);
  Result.RepeatDelay := Store.ReadIntegerWithin(KeyRepeatDelaySetting, Result.RepeatDelay,
    MinimumKeyRepeatDelay, MaximumKeyRepeatDelay);
  Result.RepeatRate := Store.ReadIntegerWithin(KeyRepeatRateSetting, Result.RepeatRate,
    MinimumKeyRepeatRate, MaximumKeyRepeatRate);
end;

procedure RememberKeyboardSettings(Store: TSettings; const Settings: TKeyboardSettings; Scope: TSettingsScopeKind);
begin
  Store.WriteString(KeyboardLayoutSetting, string(PChar(@Settings.Layout[0])), Scope);
  Store.WriteInteger(KeyRepeatDelaySetting, Settings.RepeatDelay, Scope);
  Store.WriteInteger(KeyRepeatRateSetting, Settings.RepeatRate, Scope);
end;

end.

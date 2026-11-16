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
  System calls for the keyboards' settings (CallGetKeyboardSettings,
  CallSetKeyboardSettings, CallDescribeKeyboardLayout).

  Keys become characters in the kernel, for the console and the display
  server's input alike (Drivers.KeyboardTranslation), so the layout is
  the kernel's: one set of tables (Drivers.KeyboardLayouts) for every
  keyboard and every program. Changing it is root's: the display server
  (root) changes it for whoever sits at the screen, as it does the
  mouse's settings, and the system settings service sets the system's
  at start.
}
unit Processes.KeyboardCalls;

{$mode objfpc}

interface

function PerformGetKeyboardSettings(SettingsAddress: QWord): Int64;
function PerformSetKeyboardSettings(SettingsAddress: QWord): Int64;
function PerformDescribeKeyboardLayout(Index: QWord; LayoutAddress: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Processes.Process,
  Processes.Thread,
  Processes.UserAccess,
  Drivers.KeyboardLayouts,
  Drivers.KeyboardRepeat;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function PerformGetKeyboardSettings(SettingsAddress: QWord): Int64;
var
  Settings: TAbiKeyboardSettings;
begin
  FillMemory(@Settings, SizeOf(Settings), 0);
  CopyText(@Settings.Layout[0], CurrentKeyboardLayoutName, KeyboardLayoutNameCapacity);
  Settings.RepeatDelay := KeyRepeatDelay;
  Settings.RepeatRate := KeyRepeatRate;
  Result := -Int64(CopyToUser(SettingsAddress, @Settings, SizeOf(Settings)));
end;

function PerformSetKeyboardSettings(SettingsAddress: QWord): Int64;
var
  Settings: TAbiKeyboardSettings;
  Error: LongInt;
begin
  if CurrentProcess^.Credentials.EffectiveUserId <> RootUserId then
    Exit(Failure(ErrorNotPermitted));
  Error := CopyFromUser(@Settings, SettingsAddress, SizeOf(Settings));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Settings.Layout[KeyboardLayoutNameCapacity - 1] := #0;
  if not SelectKeyboardLayout(@Settings.Layout[0]) then
    Exit(Failure(ErrorNotFound));
  SetKeyRepeat(Settings.RepeatDelay, Settings.RepeatRate);
  Result := 0;
end;

function PerformDescribeKeyboardLayout(Index: QWord; LayoutAddress: QWord): Int64;
var
  Layout: TAbiKeyboardLayout;
begin
  if (Index > High(Integer)) or (KeyboardLayoutName(Integer(Index)) = nil) then
    Exit(Failure(ErrorNotFound));
  FillMemory(@Layout, SizeOf(Layout), 0);
  CopyText(@Layout.Name[0], KeyboardLayoutName(Integer(Index)), KeyboardLayoutNameCapacity);
  CopyText(@Layout.Description[0], KeyboardLayoutDescription(Integer(Index)), KeyboardLayoutDescriptionCapacity);
  Result := -Int64(CopyToUser(LayoutAddress, @Layout, SizeOf(Layout)));
end;

end.

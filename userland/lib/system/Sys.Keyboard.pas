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
  The keyboards' layout and key repeat, which the kernel keeps for every
  keyboard (keys become characters there, for the console and the
  display server alike: one set of layout tables for the whole system).

  Anyone may read them and list the layouts; changing them is root's.
  On the screen they are the user's (the display server changes them for
  whoever sits there, Windowing.KeyboardSettings), and the system's are
  given to the kernel at start by the system settings service.
}
unit Sys.Keyboard;

{$mode objfpc}{$H+}

interface

uses
  Abi.SystemCalls;

type
  TKeyboardSettings = record
    { The layout's name ("us"); at most KeyboardLayoutNameCapacity - 1
      characters reach the kernel. }
    Layout: string;
    { Milliseconds before a held key repeats. }
    RepeatDelay: LongWord;
    { Repeats a second. }
    RepeatRate: LongWord;
  end;

  TKeyboardLayoutDescription = record
    Name: string;
    Description: string;
  end;

{ What the kernel has now. }
function GetKeyboardSettings(out Settings: TKeyboardSettings): LongInt;
{ New settings (root only): ErrorNotFound for a layout the kernel does
  not have; the repeat is kept within its range. }
function SetKeyboardSettings(const Settings: TKeyboardSettings): LongInt;
{ The layout numbered Index (from 0); False past the last. }
function DescribeKeyboardLayout(Index: Integer; out Layout: TKeyboardLayoutDescription): Boolean;
function KeyboardLayoutCount: Integer;
{ Settings with Layout as its layout, the repeat at the kernel's
  defaults. }
function NewKeyboardSettings(const Layout: string): TKeyboardSettings;

const
  DefaultKeyboardLayout = 'us';
  DefaultKeyRepeatDelay = 500;
  DefaultKeyRepeatRate = 11;

implementation

uses
  SysUtils,
  Sys.Kernel,
  Sys.Errors;

{ The text the kernel wrote into a fixed field: up to its terminating
  zero, and at most one character short of the field. }
function FieldText(const Field: array of Char): string;
var
  Count: Integer;
begin
  Count := 0;
  while (Count < High(Field)) and (Field[Count] <> #0) do
    Inc(Count);
  SetString(Result, PChar(@Field[0]), Count);
end;

function GetKeyboardSettings(out Settings: TKeyboardSettings): LongInt;
var
  Kernel: TAbiKeyboardSettings;
begin
  Settings := NewKeyboardSettings(DefaultKeyboardLayout);
  Result := ErrorCodeOf(KernelGetKeyboardSettings(Kernel));
  if Result <> ErrorNone then
    Exit;
  Settings.Layout := FieldText(Kernel.Layout);
  Settings.RepeatDelay := Kernel.RepeatDelay;
  Settings.RepeatRate := Kernel.RepeatRate;
end;

function SetKeyboardSettings(const Settings: TKeyboardSettings): LongInt;
var
  Kernel: TAbiKeyboardSettings;
begin
  Kernel := Default(TAbiKeyboardSettings);
  StrPLCopy(@Kernel.Layout[0], Settings.Layout, KeyboardLayoutNameCapacity - 1);
  Kernel.RepeatDelay := Settings.RepeatDelay;
  Kernel.RepeatRate := Settings.RepeatRate;
  Result := ErrorCodeOf(KernelSetKeyboardSettings(Kernel));
end;

function DescribeKeyboardLayout(Index: Integer; out Layout: TKeyboardLayoutDescription): Boolean;
var
  Kernel: TAbiKeyboardLayout;
begin
  Layout := Default(TKeyboardLayoutDescription);
  if Index < 0 then
    Exit(False);
  Result := KernelDescribeKeyboardLayout(QWord(Index), Kernel) >= 0;
  if not Result then
    Exit;
  Layout.Name := FieldText(Kernel.Name);
  Layout.Description := FieldText(Kernel.Description);
end;

function KeyboardLayoutCount: Integer;
var
  Layout: TKeyboardLayoutDescription;
begin
  Result := 0;
  while DescribeKeyboardLayout(Result, Layout) do
    Inc(Result);
end;

function NewKeyboardSettings(const Layout: string): TKeyboardSettings;
begin
  Result := Default(TKeyboardSettings);
  Result.Layout := Copy(Layout, 1, KeyboardLayoutNameCapacity - 1);
  Result.RepeatDelay := DefaultKeyRepeatDelay;
  Result.RepeatRate := DefaultKeyRepeatRate;
end;

end.

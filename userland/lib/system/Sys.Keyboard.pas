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

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

type
  TKeyboardSettings = record
    Layout: array[0..KeyboardLayoutNameCapacity - 1] of Char;
    { Milliseconds before a held key repeats. }
    RepeatDelay: LongWord;
    { Repeats a second. }
    RepeatRate: LongWord;
  end;

  TKeyboardLayoutDescription = record
    Name: array[0..KeyboardLayoutNameCapacity - 1] of Char;
    Description: array[0..KeyboardLayoutDescriptionCapacity - 1] of Char;
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
function NewKeyboardSettings(Layout: PChar): TKeyboardSettings;

const
  DefaultKeyboardLayout: PChar = 'us';
  DefaultKeyRepeatDelay = 500;
  DefaultKeyRepeatRate = 11;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Kernel,
  Sys.Errors;

function GetKeyboardSettings(out Settings: TKeyboardSettings): LongInt;
var
  Kernel: TAbiKeyboardSettings;
begin
  Settings := NewKeyboardSettings(DefaultKeyboardLayout);
  Result := ErrorCodeOf(KernelGetKeyboardSettings(Kernel));
  if Result <> ErrorNone then
    Exit;
  CopyText(@Settings.Layout[0], @Kernel.Layout[0], KeyboardLayoutNameCapacity);
  Settings.RepeatDelay := Kernel.RepeatDelay;
  Settings.RepeatRate := Kernel.RepeatRate;
end;

function SetKeyboardSettings(const Settings: TKeyboardSettings): LongInt;
var
  Kernel: TAbiKeyboardSettings;
begin
  FillMemory(@Kernel, SizeOf(Kernel), 0);
  CopyText(@Kernel.Layout[0], @Settings.Layout[0], KeyboardLayoutNameCapacity);
  Kernel.RepeatDelay := Settings.RepeatDelay;
  Kernel.RepeatRate := Settings.RepeatRate;
  Result := ErrorCodeOf(KernelSetKeyboardSettings(Kernel));
end;

function DescribeKeyboardLayout(Index: Integer; out Layout: TKeyboardLayoutDescription): Boolean;
var
  Kernel: TAbiKeyboardLayout;
begin
  FillMemory(@Layout, SizeOf(Layout), 0);
  if Index < 0 then
    Exit(False);
  Result := KernelDescribeKeyboardLayout(QWord(Index), Kernel) >= 0;
  if not Result then
    Exit;
  CopyText(@Layout.Name[0], @Kernel.Name[0], KeyboardLayoutNameCapacity);
  CopyText(@Layout.Description[0], @Kernel.Description[0], KeyboardLayoutDescriptionCapacity);
end;

function KeyboardLayoutCount: Integer;
var
  Layout: TKeyboardLayoutDescription;
begin
  Result := 0;
  while DescribeKeyboardLayout(Result, Layout) do
    Inc(Result);
end;

function NewKeyboardSettings(Layout: PChar): TKeyboardSettings;
begin
  FillMemory(@Result, SizeOf(Result), 0);
  CopyText(@Result.Layout[0], Layout, KeyboardLayoutNameCapacity);
  Result.RepeatDelay := DefaultKeyRepeatDelay;
  Result.RepeatRate := DefaultKeyRepeatRate;
end;

end.

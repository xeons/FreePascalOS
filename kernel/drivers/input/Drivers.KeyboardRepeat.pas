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
  The key repeat: how long a key is held before it repeats, and how fast
  it then repeats.

  PS/2 keyboards repeat by themselves (their "typematic" setting): the
  driver registers a routine here and is told whenever the settings
  change, and gives the keyboard the nearest it can do. USB keyboards
  send no repeats (their keys do not repeat yet). The settings are the
  kernel's for every keyboard, changed with CallSetKeyboardSettings.
}
unit Drivers.KeyboardRepeat;

{$mode objfpc}

interface

const
  DefaultKeyRepeatDelay = 500;
  DefaultKeyRepeatRate = 11;

type
  TKeyRepeatChanged = procedure;

{ Milliseconds before a held key repeats, and repeats a second. }
function KeyRepeatDelay: LongWord;
function KeyRepeatRate: LongWord;
{ New settings, each kept within the range the ABI gives; the driver's
  routine is called (at passive level). }
procedure SetKeyRepeat(Delay, Rate: LongWord);
{ The PS/2 driver's routine, called after every change. }
procedure SetKeyRepeatChangedRoutine(Routine: TKeyRepeatChanged);

implementation

uses
  Abi.SystemCalls;

var
  CurrentDelay: LongWord = DefaultKeyRepeatDelay;
  CurrentRate: LongWord = DefaultKeyRepeatRate;
  ChangedRoutine: TKeyRepeatChanged = nil;

function KeyRepeatDelay: LongWord;
begin
  Result := CurrentDelay;
end;

function KeyRepeatRate: LongWord;
begin
  Result := CurrentRate;
end;

function Within(Value, Lowest, Highest: LongWord): LongWord;
begin
  if Value < Lowest then
    Exit(Lowest);
  if Value > Highest then
    Exit(Highest);
  Result := Value;
end;

procedure SetKeyRepeat(Delay, Rate: LongWord);
begin
  CurrentDelay := Within(Delay, MinimumKeyRepeatDelay, MaximumKeyRepeatDelay);
  CurrentRate := Within(Rate, MinimumKeyRepeatRate, MaximumKeyRepeatRate);
  if ChangedRoutine <> nil then
    ChangedRoutine();
end;

procedure SetKeyRepeatChangedRoutine(Routine: TKeyRepeatChanged);
begin
  ChangedRoutine := Routine;
end;

end.

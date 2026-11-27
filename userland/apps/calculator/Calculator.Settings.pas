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
  What the calculator remembers from one run to the next, in the user's
  settings (libconfiguration), group Calculator:

    Mode = standard | scientific | programmer
    Angles = degrees | radians | gradians
    Base = 2 | 8 | 10 | 16          the programmer mode's
    WordBits = 8 | 16 | 32 | 64     the programmer mode's
    History = true | false          the history beside the keypad

  Each is written as soon as it is chosen; a change made elsewhere (a
  second calculator, the settings tool) is taken at once.
}
unit Calculator.Settings;

{$mode objfpc}
{$H+}

interface

uses
  Calculator.MathFunctions,
  Calculator.Engine;

const
  CalculatorSettingsGroup = 'Calculator';

type
  TCalculatorSettings = record
    Mode: TCalculatorMode;
    Angles: TAngleUnit;
    Base: LongInt;
    WordBits: LongInt;
    HistoryShown: Boolean;
  end;

const
  ModeNames: array[TCalculatorMode] of string = ('standard', 'scientific', 'programmer');
  AngleNames: array[TAngleUnit] of string = ('degrees', 'radians', 'gradians');

function RememberedSettings: TCalculatorSettings;
procedure RememberMode(Mode: TCalculatorMode);
procedure RememberAngles(Angles: TAngleUnit);
procedure RememberBase(Base: LongInt);
procedure RememberWordBits(Bits: LongInt);
procedure RememberHistoryShown(Shown: Boolean);

implementation

uses
  Configuration.Settings,
  Configuration.Locations;

const
  ModeSetting = 'Calculator/Mode';
  AnglesSetting = 'Calculator/Angles';
  BaseSetting = 'Calculator/Base';
  WordBitsSetting = 'Calculator/WordBits';
  HistorySetting = 'Calculator/History';

function RememberedSettings: TCalculatorSettings;
var
  Store: TSettings;
  Name: string;
  Mode: TCalculatorMode;
  Angles: TAngleUnit;
begin
  Store := OpenSettings;
  try
    Result.Mode := ModeStandard;
    Name := Store.ReadString(ModeSetting, ModeNames[ModeStandard]);
    for Mode := Low(TCalculatorMode) to High(TCalculatorMode) do
      if ModeNames[Mode] = Name then
        Result.Mode := Mode;
    Result.Angles := AngleDegrees;
    Name := Store.ReadString(AnglesSetting, AngleNames[AngleDegrees]);
    for Angles := Low(TAngleUnit) to High(TAngleUnit) do
      if AngleNames[Angles] = Name then
        Result.Angles := Angles;
    Result.Base := Store.ReadIntegerWithin(BaseSetting, 10, 2, 16);
    if not (Result.Base in [2, 8, 10, 16]) then
      Result.Base := 10;
    Result.WordBits := Store.ReadIntegerWithin(WordBitsSetting, 64, 8, 64);
    if not (Result.WordBits in [8, 16, 32, 64]) then
      Result.WordBits := 64;
    Result.HistoryShown := Store.ReadBoolean(HistorySetting, False);
  finally
    Store.Free;
  end;
end;

{ Freeing the settings flushes them. }
procedure RememberText(const Key, Value: string);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Store.WriteString(Key, Value);
  finally
    Store.Free;
  end;
end;

procedure RememberNumber(const Key: string; Value: LongInt);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Store.WriteInteger(Key, Value);
  finally
    Store.Free;
  end;
end;

procedure RememberMode(Mode: TCalculatorMode);
begin
  RememberText(ModeSetting, ModeNames[Mode]);
end;

procedure RememberAngles(Angles: TAngleUnit);
begin
  RememberText(AnglesSetting, AngleNames[Angles]);
end;

procedure RememberBase(Base: LongInt);
begin
  RememberNumber(BaseSetting, Base);
end;

procedure RememberWordBits(Bits: LongInt);
begin
  RememberNumber(WordBitsSetting, Bits);
end;

procedure RememberHistoryShown(Shown: Boolean);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Store.WriteBoolean(HistorySetting, Shown);
  finally
    Store.Free;
  end;
end;

end.

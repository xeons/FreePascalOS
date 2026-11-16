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
  What Notepad remembers from one run to the next, in the user's
  settings (libconfiguration), group Notepad:

    WordWrap = true|false
    StatusBar = true|false
    Font/Family = "text" | "fixed"     the interface's face or the fixed one
    Font/Size = 110                    tenths of a point
    Font/Bold = true|false

  Each is written as soon as it is chosen, so a crash or the session
  ending loses nothing. Values the user (or the system's settings) has
  not set are what the edit box starts with.
}
unit Notepad.Settings;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Fonts,
  Controls.TextEdit;

type
  TNotepadFormat = record
    WordWrap: Boolean;
    StatusBar: Boolean;
    FontFamily: TFontFamily;
    FontPointTenths: LongWord;
    FontBold: Boolean;
  end;

{ The remembered format; what Editor has now for anything not set. }
function RememberedFormat(Editor: TTextEdit): TNotepadFormat;
procedure RememberWordWrap(WordWrap: Boolean);
procedure RememberStatusBar(Visible: Boolean);
procedure RememberFont(Family: TFontFamily; PointTenths: LongWord; Bold: Boolean);

implementation

uses
  Configuration.Settings,
  Configuration.Locations;

const
  WordWrapSetting = 'Notepad/WordWrap';
  StatusBarSetting = 'Notepad/StatusBar';
  FontFamilySetting = 'Notepad/Font/Family';
  FontSizeSetting = 'Notepad/Font/Size';
  FontBoldSetting = 'Notepad/Font/Bold';
  { The families as the setting names them. }
  FamilySettingNames: array[TFontFamily] of string = ('text', 'fixed', 'mono');
  SmallestPointTenths = 40;
  LargestPointTenths = 1000;

function RememberedFormat(Editor: TTextEdit): TNotepadFormat;
var
  Store: TSettings;
  FamilyName: string;
  Family: TFontFamily;
begin
  Store := OpenSettings;
  Result.WordWrap := Store.ReadBoolean(WordWrapSetting, Editor.WordWrap);
  Result.StatusBar := Store.ReadBoolean(StatusBarSetting, True);
  FamilyName := Store.ReadString(FontFamilySetting, FamilySettingNames[Editor.FontFamily]);
  Result.FontFamily := FontFamilyText;
  for Family := Low(TFontFamily) to High(TFontFamily) do
    if FamilySettingNames[Family] = FamilyName then
      Result.FontFamily := Family;
  Result.FontPointTenths := Store.ReadIntegerWithin(FontSizeSetting, Editor.FontPointTenths, SmallestPointTenths,
    LargestPointTenths);
  Result.FontBold := Store.ReadBoolean(FontBoldSetting, Editor.FontBold);
  Store.Free;
end;

{ Freeing the settings flushes them. }
procedure RememberWordWrap(WordWrap: Boolean);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteBoolean(WordWrapSetting, WordWrap);
  Store.Free;
end;

procedure RememberStatusBar(Visible: Boolean);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteBoolean(StatusBarSetting, Visible);
  Store.Free;
end;

procedure RememberFont(Family: TFontFamily; PointTenths: LongWord; Bold: Boolean);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteString(FontFamilySetting, FamilySettingNames[Family]);
  Store.WriteInteger(FontSizeSetting, PointTenths);
  Store.WriteBoolean(FontBoldSetting, Bold);
  Store.Free;
end;

end.

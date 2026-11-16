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
  Controls.TextEdit;

const
  NotepadSettingsGroup = 'Notepad';

type
  TNotepadFormat = record
    WordWrap: Boolean;
    StatusBar: Boolean;
    FontFamilyIsFixed: Boolean;
    FontPointTenths: LongWord;
    FontBold: Boolean;
  end;

{ The remembered format; what Editor has now for anything not set. }
function RememberedFormat(Editor: TTextEdit): TNotepadFormat;
procedure RememberWordWrap(WordWrap: Boolean);
procedure RememberStatusBar(Visible: Boolean);
procedure RememberFont(FamilyIsFixed: Boolean; PointTenths: LongWord; Bold: Boolean);

implementation

uses
  Windowing.Fonts,
  Configuration.Settings,
  Configuration.Locations;

const
  WordWrapSetting = 'Notepad/WordWrap';
  StatusBarSetting = 'Notepad/StatusBar';
  FontFamilySetting = 'Notepad/Font/Family';
  FontSizeSetting = 'Notepad/Font/Size';
  FontBoldSetting = 'Notepad/Font/Bold';
  FixedFamilyName = 'fixed';
  TextFamilyName = 'text';
  SmallestPointTenths = 40;
  LargestPointTenths = 1000;

function RememberedFormat(Editor: TTextEdit): TNotepadFormat;
var
  Store: TSettings;
  FamilyName: string;
begin
  Store := OpenSettings;
  Result.WordWrap := Store.ReadBoolean(WordWrapSetting, Editor.WordWrap);
  Result.StatusBar := Store.ReadBoolean(StatusBarSetting, True);
  FamilyName := TextFamilyName;
  if Editor.FontFamily = FontFamilyFixed then
    FamilyName := FixedFamilyName;
  Result.FontFamilyIsFixed := Store.ReadString(FontFamilySetting, FamilyName) = FixedFamilyName;
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

procedure RememberFont(FamilyIsFixed: Boolean; PointTenths: LongWord; Bold: Boolean);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  if FamilyIsFixed then
    Store.WriteString(FontFamilySetting, FixedFamilyName)
  else
    Store.WriteString(FontFamilySetting, TextFamilyName);
  Store.WriteInteger(FontSizeSetting, PointTenths);
  Store.WriteBoolean(FontBoldSetting, Bold);
  Store.Free;
end;

end.

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
  What Paint remembers from one run to the next, in the user's settings
  (libconfiguration), group Paint:

    StatusBar = true|false       the status bar shown
    PixelGrid = true|false       the grid between pixels at high zoom
    JpegQuality = 90             the quality JPEGs were last saved at
    NewWidth = 480, NewHeight = 320   the size File > New last made
    Font/Family = 0              the text tool's font (Windowing.Fonts'
    Font/Size = 240                family by number, tenths of a point,
    Font/Bold = false              bold)

  Each is written as soon as it is chosen.
}
unit Paint.Settings;

{$mode objfpc}
{$H+}

interface

const
  PaintSettingsGroup = 'Paint';
  DefaultNewWidth = 480;
  DefaultNewHeight = 320;

type
  TPaintPreferences = record
    StatusBar: Boolean;
    PixelGrid: Boolean;
    JpegQuality: LongInt;
    NewWidth: LongInt;
    NewHeight: LongInt;
    FontFamily: LongInt;
    FontPointTenths: LongWord;
    FontBold: Boolean;
  end;

function RememberedPreferences: TPaintPreferences;
procedure RememberStatusBar(Visible: Boolean);
procedure RememberPixelGrid(Visible: Boolean);
procedure RememberJpegQuality(Quality: LongInt);
procedure RememberNewSize(Width, Height: LongInt);
procedure RememberTextFont(Family: LongInt; PointTenths: LongWord; Bold: Boolean);

implementation

uses
  Configuration.Settings,
  Configuration.Locations,
  Paint.FileFormats;

const
  StatusBarSetting = 'Paint/StatusBar';
  PixelGridSetting = 'Paint/PixelGrid';
  JpegQualitySetting = 'Paint/JpegQuality';
  NewWidthSetting = 'Paint/NewWidth';
  NewHeightSetting = 'Paint/NewHeight';
  FontFamilySetting = 'Paint/Font/Family';
  FontSizeSetting = 'Paint/Font/Size';
  FontBoldSetting = 'Paint/Font/Bold';
  LargestSide = 16384;
  DefaultFontPointTenths = 240;

function RememberedPreferences: TPaintPreferences;
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Result.StatusBar := Store.ReadBoolean(StatusBarSetting, True);
    Result.PixelGrid := Store.ReadBoolean(PixelGridSetting, True);
    Result.JpegQuality := Store.ReadIntegerWithin(JpegQualitySetting, DefaultJpegQuality, 1, 100);
    Result.NewWidth := Store.ReadIntegerWithin(NewWidthSetting, DefaultNewWidth, 1, LargestSide);
    Result.NewHeight := Store.ReadIntegerWithin(NewHeightSetting, DefaultNewHeight, 1, LargestSide);
    Result.FontFamily := Store.ReadIntegerWithin(FontFamilySetting, 0, 0, 2);
    Result.FontPointTenths := Store.ReadIntegerWithin(FontSizeSetting, DefaultFontPointTenths, 40, 4000);
    Result.FontBold := Store.ReadBoolean(FontBoldSetting, False);
  finally
    Store.Free;
  end;
end;

procedure RememberStatusBar(Visible: Boolean);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteBoolean(StatusBarSetting, Visible);
  Store.Free;
end;

procedure RememberPixelGrid(Visible: Boolean);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteBoolean(PixelGridSetting, Visible);
  Store.Free;
end;

procedure RememberJpegQuality(Quality: LongInt);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteInteger(JpegQualitySetting, Quality);
  Store.Free;
end;

procedure RememberNewSize(Width, Height: LongInt);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteInteger(NewWidthSetting, Width);
  Store.WriteInteger(NewHeightSetting, Height);
  Store.Free;
end;

procedure RememberTextFont(Family: LongInt; PointTenths: LongWord; Bold: Boolean);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteInteger(FontFamilySetting, Family);
  Store.WriteInteger(FontSizeSetting, PointTenths);
  Store.WriteBoolean(FontBoldSetting, Bold);
  Store.Free;
end;

end.

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
  What the image viewer remembers from one run to the next, in the
  user's settings (libconfiguration), group ImageViewer:

    ColorManagement = true | false   colours converted to sRGB from the
                                     file's profile (true unless set)
    Properties = true | false        the properties panel shown
    PropertiesWidth = 240            its width, logical units
    StatusBar = true | false
    ToolBar = true | false

  Each is written as soon as it is chosen; a change made elsewhere is
  taken at once.
}
unit ImageViewer.Settings;

{$mode objfpc}
{$H+}

interface

const
  ImageViewerSettingsGroup = 'ImageViewer';
  DefaultPropertiesWidth = 240;

type
  TImageViewerSettings = record
    ColorManagement: Boolean;
    PropertiesShown: Boolean;
    PropertiesWidth: LongInt;
    StatusBarShown: Boolean;
    ToolBarShown: Boolean;
  end;

function RememberedSettings: TImageViewerSettings;
procedure RememberColorManagement(Value: Boolean);
procedure RememberPropertiesShown(Value: Boolean);
procedure RememberPropertiesWidth(Value: LongInt);
procedure RememberStatusBarShown(Value: Boolean);
procedure RememberToolBarShown(Value: Boolean);

implementation

uses
  Configuration.Settings,
  Configuration.Locations;

const
  ColorManagementSetting = 'ImageViewer/ColorManagement';
  PropertiesSetting = 'ImageViewer/Properties';
  PropertiesWidthSetting = 'ImageViewer/PropertiesWidth';
  StatusBarSetting = 'ImageViewer/StatusBar';
  ToolBarSetting = 'ImageViewer/ToolBar';

function RememberedSettings: TImageViewerSettings;
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Result.ColorManagement := Store.ReadBoolean(ColorManagementSetting, True);
    Result.PropertiesShown := Store.ReadBoolean(PropertiesSetting, False);
    Result.PropertiesWidth := Store.ReadIntegerWithin(PropertiesWidthSetting, DefaultPropertiesWidth, 120, 800);
    Result.StatusBarShown := Store.ReadBoolean(StatusBarSetting, True);
    Result.ToolBarShown := Store.ReadBoolean(ToolBarSetting, True);
  finally
    Store.Free;
  end;
end;

{ Freeing the settings flushes them. }
procedure RememberFlag(const Key: string; Value: Boolean);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Store.WriteBoolean(Key, Value);
  finally
    Store.Free;
  end;
end;

procedure RememberColorManagement(Value: Boolean);
begin
  RememberFlag(ColorManagementSetting, Value);
end;

procedure RememberPropertiesShown(Value: Boolean);
begin
  RememberFlag(PropertiesSetting, Value);
end;

procedure RememberPropertiesWidth(Value: LongInt);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Store.WriteInteger(PropertiesWidthSetting, Value);
  finally
    Store.Free;
  end;
end;

procedure RememberStatusBarShown(Value: Boolean);
begin
  RememberFlag(StatusBarSetting, Value);
end;

procedure RememberToolBarShown(Value: Boolean);
begin
  RememberFlag(ToolBarSetting, Value);
end;

end.

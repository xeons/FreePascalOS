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
  Options > Content: block pop-up windows, load images, enable
  JavaScript (Advanced...: what scripts may do), the default font and
  size (kept for when the engine takes a default font), and the
  languages pages are asked for in (Choose...).
}
unit Browser.Options.Content;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Toggles,
  Controls.ComboBox,
  Browser.Settings,
  Browser.Options.Pane;

type
  TContentPane = class(TOptionsPane)
  private
    FBlockPopups: TCheckBox;
    FLoadImages: TCheckBox;
    FJavaScript: TCheckBox;
    FFont: TComboBox;
    FSize: TComboBox;
    FScriptsMove, FScriptsRaise, FScriptsMenus, FScriptsStatus: Boolean;
    FLanguages: string;
    procedure AdvancedClicked(Sender: TControl);
    procedure LanguagesClicked(Sender: TControl);
  public
    procedure Build; override;
    procedure Load(constref Settings: TBrowserSettings); override;
    procedure Store(var Settings: TBrowserSettings); override;
  end;

implementation

uses
  SysUtils,
  Browser.Options.Dialogs;

const
  FontNames: array[0..2] of string = ('Sans', 'Serif', 'Monospace');
  FontSizes: array[0..8] of string = ('9', '10', '11', '12', '13', '14', '16', '18', '20');

procedure TContentPane.Build;
var
  Group: TControl;
begin
  FBlockPopups := AddCheck(Page, '&Block pop-up windows', PaneMargin, 12);
  FLoadImages := AddCheck(Page, 'Load &images automatically', PaneMargin, 12 + RowHeight);
  FJavaScript := AddCheck(Page, 'Enable &JavaScript', PaneMargin, 12 + 2 * RowHeight);
  AddButton(Page, 'Ad&vanced...', 440, 12 + 2 * RowHeight, 100, @AdvancedClicked);
  Group := AddGroup('Fonts', 100, 64);
  AddLabel(Group, 'Default &font:', 10, GroupTop, 100);
  FFont := AddCombo(Group, FontNames, 110, GroupTop, 180);
  AddLabel(Group, '&Size:', 310, GroupTop, 50);
  FSize := AddCombo(Group, FontSizes, 360, GroupTop, 70);
  Group := AddGroup('Languages', 172, 64);
  AddLabel(Group, 'Choose your preferred language for displaying pages', 10, GroupTop, 380);
  AddButton(Group, 'Ch&oose...', 420, GroupTop, 100, @LanguagesClicked);
end;

procedure TContentPane.Load(constref Settings: TBrowserSettings);
var
  Index: Integer;
begin
  FBlockPopups.Checked := Settings.BlockPopups;
  FLoadImages.Checked := Settings.LoadImages;
  FJavaScript.Checked := Settings.JavaScript;
  FFont.ItemIndex := 0;
  for Index := 0 to High(FontNames) do
    if SameText(FontNames[Index], Settings.DefaultFont) then
      FFont.ItemIndex := Index;
  FSize.ItemIndex := 6;
  for Index := 0 to High(FontSizes) do
    if FontSizes[Index] = IntToStr(Settings.DefaultFontSize) then
      FSize.ItemIndex := Index;
  FScriptsMove := Settings.ScriptsMoveWindows;
  FScriptsRaise := Settings.ScriptsRaiseWindows;
  FScriptsMenus := Settings.ScriptsDisableMenus;
  FScriptsStatus := Settings.ScriptsChangeStatus;
  FLanguages := Settings.Languages;
end;

procedure TContentPane.Store(var Settings: TBrowserSettings);
begin
  Settings.BlockPopups := FBlockPopups.Checked;
  Settings.LoadImages := FLoadImages.Checked;
  Settings.JavaScript := FJavaScript.Checked;
  Settings.DefaultFont := FontNames[FFont.ItemIndex];
  Settings.DefaultFontSize := StrToIntDef(FontSizes[FSize.ItemIndex], 16);
  Settings.ScriptsMoveWindows := FScriptsMove;
  Settings.ScriptsRaiseWindows := FScriptsRaise;
  Settings.ScriptsDisableMenus := FScriptsMenus;
  Settings.ScriptsChangeStatus := FScriptsStatus;
  Settings.Languages := FLanguages;
end;

procedure TContentPane.AdvancedClicked(Sender: TControl);
begin
  EditScriptOptions(Owner, FScriptsMove, FScriptsRaise, FScriptsMenus, FScriptsStatus);
end;

procedure TContentPane.LanguagesClicked(Sender: TControl);
begin
  EditLanguages(Owner, FLanguages);
end;

end.

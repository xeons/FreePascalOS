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
  The Appearance page: the theme, chosen from the built-in ones
  (Windowing.Theme) in a list, with a picture of the one picked
  (ControlPanel.ThemePreview). Applying asks the system settings service
  to keep it (SystemRequestSetTheme: anyone may) as Appearance/Theme,
  which the display server and every program follow at once
  (Windowing.ThemeSettings).

  Says "applied theme KEY" when applied, and where the list's lines are
  ("place appearance-theme-KEY X Y").
}
unit ControlPanel.AppearancePage;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Controls.Base,
  Controls.Window,
  Controls.Labels,
  Controls.ListBox,
  ControlPanel.Pages,
  ControlPanel.ThemePreview;

type
  TAppearancePage = class(TSettingsPage)
  private
    FThemes: TListBox;
    FPreview: TThemePreview;
    FLoadedIndex: LongInt;
    procedure ThemePicked(Sender: TControl);
  protected
    procedure LoadSettings; override;
  public
    constructor CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string); override;
    function PageName: string; override;
    function SettingsGroups: TStringArray; override;
    function Apply: Boolean; override;
    procedure TellPlaces; override;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.SystemSettings,
  Windowing.Theme,
  Windowing.ThemeSettings,
  Windowing.Connection,
  Controls.MessageBoxes,
  ControlPanel.Administrator,
  ControlPanel.Report;

const
  { Logical units. }
  ListWidth = 140;
  ListHeight = 120;
  PreviewHeight = 220;

constructor TAppearancePage.CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string);
var
  Caption: TLabel;
  Index: LongInt;
begin
  inherited CreatePage(AParent, AWindow, ATitle);
  Caption := TLabel.Create(Self);
  Caption.Text := '&Theme:';
  Caption.SetBounds(PageMargin, 26, ListWidth, 18);
  FThemes := TListBox.Create(Self);
  FThemes.SetBounds(PageMargin, 46, ListWidth, ListHeight);
  for Index := 0 to BuiltInThemeCount - 1 do
    FThemes.Items.Add(BuiltInTheme(Index).DisplayName);
  FThemes.OnChange := @ThemePicked;
  Caption := TLabel.Create(Self);
  Caption.Text := 'Preview:';
  Caption.SetBounds(PageMargin + ListWidth + 14, 26, 120, 18);
  FPreview := TThemePreview.Create(Self);
  FPreview.SetBounds(PageMargin + ListWidth + 14, 46, PageWidth - 2 * PageMargin - ListWidth - 14, PreviewHeight);
  Caption := TLabel.Create(Self);
  Caption.Text := 'The theme is the same for everyone using this computer.';
  Caption.SetBounds(PageMargin, 46 + PreviewHeight + 14, PageWidth - 2 * PageMargin, 18);
end;

function TAppearancePage.PageName: string;
begin
  Result := 'appearance';
end;

function TAppearancePage.SettingsGroups: TStringArray;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := AppearanceGroup;
end;

{ The built-in theme Key is (the default's when none is). }
function ThemeIndexOf(const Key: string): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to BuiltInThemeCount - 1 do
    if BuiltInTheme(Index).Key = Key then
      Exit(Index);
  Result := 0;
end;

procedure TAppearancePage.LoadSettings;
begin
  FLoadedIndex := ThemeIndexOf(SystemThemeKey);
  FThemes.ItemIndex := FLoadedIndex;
  FPreview.ShowTheme(BuiltInTheme(FLoadedIndex));
end;

procedure TAppearancePage.ThemePicked(Sender: TControl);
begin
  if FThemes.ItemIndex < 0 then
    Exit;
  FPreview.ShowTheme(BuiltInTheme(FThemes.ItemIndex));
  MarkModified;
end;

function TAppearancePage.Apply: Boolean;
var
  Request: TSystemSettingsRequest;
  Key: string;
  Error: LongInt;
begin
  Result := True;
  if (FThemes.ItemIndex < 0) or (FThemes.ItemIndex = FLoadedIndex) then
  begin
    inherited Apply;
    Exit;
  end;
  Key := BuiltInTheme(FThemes.ItemIndex).Key;
  Request := NewSystemSettingsRequest(SystemRequestSetTheme);
  SetRequestText(Request.Text, Key);
  Error := SendAsAnyone(Request);
  if Error <> ErrorNone then
  begin
    ShowMessageBox('Appearance', 'The theme could not be changed. ' + RefusalText(Error), MessageOk, SignError,
      Window);
    Exit(False);
  end;
  FLoadedIndex := FThemes.ItemIndex;
  Say('applied theme ' + Key);
  inherited Apply;
end;

procedure TAppearancePage.TellPlaces;
var
  Index: LongInt;
begin
  for Index := 0 to BuiltInThemeCount - 1 do
    SayPlace('appearance-theme-' + BuiltInTheme(Index).Key, Window, FThemes, Scaled(40),
      2 + Index * FThemes.ItemHeight + FThemes.ItemHeight div 2);
  SayControlPlace('appearance-preview', Window, FPreview);
end;

end.

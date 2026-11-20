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
  Tools > Settings: the home page, the search URL ("%s" for the words;
  empty for none), HTTP/3, JavaScript and the bookmarks bar.
}
unit Browser.SettingsDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Controls.Base,
  Browser.Settings;

{ Shows the settings; True (and Settings changed) on OK. }
function EditBrowserSettings(Owner: TWindow; var Settings: TBrowserSettings): Boolean;

implementation

uses
  SysUtils,
  Controls.Labels,
  Controls.EditBox,
  Controls.Toggles,
  Controls.CommonDialogs;

const
  DialogWidth = 460;
  DialogHeight = 236;
  LabelWidth = 110;
  RowHeight = 30;

type
  TSettingsDialog = class(TCommonDialog)
  private
    FHomeEdit: TEditBox;
    FSearchEdit: TEditBox;
    FHttp3Box: TCheckBox;
    FBarBox: TCheckBox;
    FScriptBox: TCheckBox;
    function AddRow(Top: LongInt; const Caption: string): TEditBox;
  protected
    procedure Showing; override;
  public
    constructor CreateSettingsDialog(AOwner: TWindow; constref Settings: TBrowserSettings);
    procedure Read(var Settings: TBrowserSettings);
  end;

function TSettingsDialog.AddRow(Top: LongInt; const Caption: string): TEditBox;
var
  Text: TLabel;
begin
  Text := TLabel.Create(Root);
  Text.Text := Caption;
  Text.SetBounds(DialogMargin, Top + 3, LabelWidth, 16);
  Result := TEditBox.Create(Root);
  Result.SetBounds(DialogMargin + LabelWidth, Top, DialogWidth - 2 * DialogMargin - LabelWidth, 22);
  Result.Anchors := [akLeft, akTop, akRight];
end;

constructor TSettingsDialog.CreateSettingsDialog(AOwner: TWindow; constref Settings: TBrowserSettings);
var
  Hint: TLabel;
  Top: LongInt;
begin
  inherited CreateDialog('Browser Settings', DialogWidth, DialogHeight, AOwner);
  Top := DialogMargin;
  FHomeEdit := AddRow(Top, '&Home page:');
  FHomeEdit.Text := Settings.HomePage;
  Inc(Top, RowHeight);
  FSearchEdit := AddRow(Top, '&Search URL:');
  FSearchEdit.Text := Settings.SearchUrl;
  Inc(Top, 24);
  Hint := TLabel.Create(Root);
  Hint.Text := '%s stands for the words; empty: no search engine.';
  Hint.SetBounds(DialogMargin + LabelWidth, Top, DialogWidth - 2 * DialogMargin - LabelWidth, 16);
  Inc(Top, RowHeight);
  FHttp3Box := TCheckBox.Create(Root);
  FHttp3Box.Text := 'Use HTTP/&3 where a site offers it';
  FHttp3Box.Checked := Settings.Http3;
  FHttp3Box.SetBounds(DialogMargin, Top, DialogWidth - 2 * DialogMargin, 20);
  Inc(Top, 24);
  FScriptBox := TCheckBox.Create(Root);
  FScriptBox.Text := 'Run &JavaScript (from the next page loaded)';
  FScriptBox.Checked := Settings.JavaScript;
  FScriptBox.SetBounds(DialogMargin, Top, DialogWidth - 2 * DialogMargin, 20);
  Inc(Top, 24);
  FBarBox := TCheckBox.Create(Root);
  FBarBox.Text := 'Show the &bookmarks bar';
  FBarBox.Checked := Settings.BookmarksBar;
  FBarBox.SetBounds(DialogMargin, Top, DialogWidth - 2 * DialogMargin, 20);
  AddOkAndCancel(DialogWidth, DialogHeight);
end;

procedure TSettingsDialog.Showing;
begin
  FocusControl(FHomeEdit);
  FHomeEdit.SelectAll;
  inherited Showing;
end;

procedure TSettingsDialog.Read(var Settings: TBrowserSettings);
begin
  Settings.HomePage := Trim(FHomeEdit.Text);
  if Settings.HomePage = '' then
    Settings.HomePage := DefaultHomePage;
  Settings.SearchUrl := Trim(FSearchEdit.Text);
  Settings.Http3 := FHttp3Box.Checked;
  Settings.BookmarksBar := FBarBox.Checked;
  Settings.JavaScript := FScriptBox.Checked;
end;

function EditBrowserSettings(Owner: TWindow; var Settings: TBrowserSettings): Boolean;
var
  Dialog: TSettingsDialog;
begin
  Dialog := TSettingsDialog.CreateSettingsDialog(Owner, Settings);
  try
    Result := Dialog.Execute;
    if Result then
      Dialog.Read(Settings);
  finally
    Dialog.Free;
  end;
end;

end.

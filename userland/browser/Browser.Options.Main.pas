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
  Options > Main: what a start shows (the home page, a blank page or
  the windows and tabs of last time), the home page (Use Current Pages,
  Use Bookmark..., Restore to Default), downloads (show the Downloads
  window, close it when done, the folder or always ask), and which
  search engine the location bar and the search bar use.
}
unit Browser.Options.Main;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.EditBox,
  Controls.Toggles,
  Controls.ComboBox,
  Browser.Settings,
  Browser.Options.Pane;

type
  TMainPane = class(TOptionsPane)
  private
    FStartup: TComboBox;
    FHomePage: TEditBox;
    FShowDownloads: TCheckBox;
    FCloseDownloads: TCheckBox;
    FSaveTo: TRadioButton;
    FAskWhere: TRadioButton;
    FFolder: TEditBox;
    FEngine: TComboBox;
    procedure UseCurrentClicked(Sender: TControl);
    procedure UseBookmarkClicked(Sender: TControl);
    procedure RestoreClicked(Sender: TControl);
    procedure BrowseClicked(Sender: TControl);
    procedure ManageClicked(Sender: TControl);
    procedure FillEngines(const Chosen: string);
  public
    procedure Build; override;
    procedure Load(constref Settings: TBrowserSettings); override;
    procedure Store(var Settings: TBrowserSettings); override;
  end;

implementation

uses
  SysUtils,
  Controls.MessageBoxes,
  Browser.InputDialog,
  Browser.Bookmarks,
  Browser.Downloads,
  Browser.Application,
  Browser.MainWindow,
  Browser.SearchEngineDialog;

procedure TMainPane.Build;
var
  Group: TControl;
  Panel: TControl;
begin
  Group := AddGroup('Startup', 8, 112);
  AddLabel(Group, 'When Browser &starts:', 10, GroupTop, 140);
  FStartup := AddCombo(Group, ['Show my home page', 'Show a blank page', 'Show my windows and tabs from last time'],
    150, GroupTop, 300);
  AddLabel(Group, 'Home &Page:', 10, GroupTop + 30, 90);
  FHomePage := AddEdit(Group, 150, GroupTop + 30, 380);
  FHomePage.Anchors := [akLeft, akTop, akRight];
  AddButton(Group, 'Use &Current Pages', 150, GroupTop + 58, 0, @UseCurrentClicked);
  AddButton(Group, 'Use &Bookmark...', 290, GroupTop + 58, 0, @UseBookmarkClicked);
  AddButton(Group, '&Restore to Default', 410, GroupTop + 58, 0, @RestoreClicked);
  Group := AddGroup('Downloads', 128, 132);
  FShowDownloads := AddCheck(Group, 'Show the &Downloads window when downloading a file', 10, GroupTop);
  FCloseDownloads := AddCheck(Group, 'C&lose it when all downloads are finished', 30, GroupTop + 22);
  Panel := AddRadioPanel(Group, 6, GroupTop + 46, PaneWidth - 40, 54);
  FSaveTo := AddRadio(Panel, 'Sa&ve files to', 4, 2, 110);
  FFolder := AddEdit(Panel, 120, 0, 270);
  AddButton(Panel, 'Br&owse...', 400, 0, 90, @BrowseClicked);
  FAskWhere := AddRadio(Panel, '&Always ask me where to save files', 4, 28);
  Group := AddGroup('Search', 268, 64);
  AddLabel(Group, 'Search &with:', 10, GroupTop, 100);
  FEngine := AddCombo(Group, [], 150, GroupTop, 250);
  AddButton(Group, '&Manage...', 410, GroupTop, 100, @ManageClicked);
end;

procedure TMainPane.FillEngines(const Chosen: string);
var
  Index: Integer;
begin
  FEngine.Items.Clear;
  FEngine.Items.Add('(None: nothing typed is sent anywhere)');
  FEngine.ItemIndex := 0;
  for Index := 0 to BrowserApp.Engines.Count - 1 do
  begin
    FEngine.Items.Add(BrowserApp.Engines[Index].Name);
    if SameText(BrowserApp.Engines[Index].Name, Chosen) then
      FEngine.ItemIndex := Index + 1;
  end;
end;

procedure TMainPane.Load(constref Settings: TBrowserSettings);
begin
  FStartup.ItemIndex := Ord(Settings.Startup);
  FHomePage.Text := Settings.HomePage;
  FShowDownloads.Checked := Settings.ShowDownloads;
  FCloseDownloads.Checked := Settings.CloseDownloadsWhenDone;
  FAskWhere.Checked := Settings.AskWhereToSave;
  FSaveTo.Checked := not Settings.AskWhereToSave;
  FFolder.Text := Settings.DownloadFolder;
  if FFolder.Text = '' then
    FFolder.Text := DownloadsFolder;
  FillEngines(Settings.SearchEngine);
end;

procedure TMainPane.Store(var Settings: TBrowserSettings);
begin
  Settings.Startup := TStartupMode(FStartup.ItemIndex);
  Settings.HomePage := Trim(FHomePage.Text);
  if Settings.HomePage = '' then
    Settings.HomePage := DefaultHomePage;
  Settings.ShowDownloads := FShowDownloads.Checked;
  Settings.CloseDownloadsWhenDone := FCloseDownloads.Checked;
  Settings.AskWhereToSave := FAskWhere.Checked;
  if Trim(FFolder.Text) = DownloadsFolder then
    Settings.DownloadFolder := ''
  else
    Settings.DownloadFolder := Trim(FFolder.Text);
  if FEngine.ItemIndex <= 0 then
  begin
    Settings.SearchEngine := '';
    Settings.SearchUrl := '';
  end
  else if FEngine.ItemIndex - 1 < BrowserApp.Engines.Count then
  begin
    Settings.SearchEngine := BrowserApp.Engines[FEngine.ItemIndex - 1].Name;
    Settings.SearchUrl := BrowserApp.Engines[FEngine.ItemIndex - 1].Url;
  end;
end;

procedure TMainPane.UseCurrentClicked(Sender: TControl);
var
  Window: TBrowserWindow;
  Index: Integer;
  Pages: string;
begin
  if not (BrowserApp.ActiveWindow is TBrowserWindow) then
    Exit;
  Window := TBrowserWindow(BrowserApp.ActiveWindow);
  Pages := '';
  for Index := 0 to Window.TabCount - 1 do
  begin
    if Pages <> '' then
      Pages := Pages + '|';
    Pages := Pages + Window.TabUrl(Index);
  end;
  if Pages <> '' then
    FHomePage.Text := Pages;
end;

procedure TMainPane.UseBookmarkClicked(Sender: TControl);
var
  Marks: TBookmarkNodeList;
  Names: array of string;
  Index, Chosen: Integer;
begin
  Marks := BrowserApp.Bookmarks.AllBookmarks;
  if Length(Marks) = 0 then
  begin
    ShowMessageBox('Set Home Page', 'There are no bookmarks yet.', MessageOk, SignInformation, Owner);
    Exit;
  end;
  Names := nil;
  SetLength(Names, Length(Marks));
  for Index := 0 to High(Marks) do
    Names[Index] := Marks[Index].ShownTitle;
  Chosen := 0;
  if ChooseFromList(Owner, 'Set Home Page', 'Choose the bookmark to use as the home page:', Names, Chosen) then
    FHomePage.Text := Marks[Chosen].Url;
end;

procedure TMainPane.RestoreClicked(Sender: TControl);
begin
  FHomePage.Text := DefaultHomePage;
end;

procedure TMainPane.BrowseClicked(Sender: TControl);
var
  Path: string;
begin
  Path := FFolder.Text;
  if AskText(Owner, 'Downloads Folder', 'The folder downloads are saved to:', Path) and (Trim(Path) <> '') then
    FFolder.Text := Trim(Path);
end;

procedure TMainPane.ManageClicked(Sender: TControl);
var
  Chosen: string;
begin
  Chosen := '';
  if FEngine.ItemIndex > 0 then
    Chosen := FEngine.Items[FEngine.ItemIndex];
  ManageSearchEngines(Owner);
  FillEngines(Chosen);
end;

end.

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
  Tools > Options...: libcontrols' preferences window with the panes of
  old - Main, Tabs, Content, Applications, Privacy, Security, Advanced
  (Browser.Options.*) - as a row of icons. OK saves every pane's
  settings (the user's settings, group Browser) and every window
  follows them at once; Help opens the help page at the pane's part.
}
unit Browser.Options;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

const
  OptionsMain = 0;
  OptionsTabs = 1;
  OptionsContent = 2;
  OptionsApplications = 3;
  OptionsPrivacy = 4;
  OptionsSecurity = 5;
  OptionsAdvanced = 6;

{ Shows the Options window (at Pane, -1 the one shown last); True if
  OK was pressed. }
function ShowOptionsWindow(Owner: TWindow; Pane: Integer): Boolean;

implementation

uses
  SysUtils,
  Controls.Base,
  Controls.PreferencesWindow,
  Browser.Settings,
  Browser.Options.Pane,
  Browser.Options.Main,
  Browser.Options.Tabs,
  Browser.Options.Content,
  Browser.Options.Applications,
  Browser.Options.Privacy,
  Browser.Options.Security,
  Browser.Options.Advanced,
  Browser.Application,
  Browser.Output;

const
  WindowHeight = 470;

var
  LastPane: Integer = 0;

type
  THelpOpener = class
    procedure HelpClicked(Sender: TControl);
  end;

procedure THelpOpener.HelpClicked(Sender: TControl);
begin
  if BrowserApp.ActiveWindow <> nil then
    BrowserApp.OpenInActiveWindow('about:help#options');
end;

function ShowOptionsWindow(Owner: TWindow; Pane: Integer): Boolean;
const
  Classes: array[0..6] of TOptionsPaneClass = (TMainPane, TTabsPane, TContentPane, TApplicationsPane, TPrivacyPane,
    TSecurityPane, TAdvancedPane);
  Captions: array[0..6] of string = ('Main', 'Tabs', 'Content', 'Applications', 'Privacy', 'Security', 'Advanced');
  Icons: array[0..6] of string = ('app-settings', 'app-web-browser', 'file-document', 'applications',
    'action-lock', 'status-security-ok', 'action-options');
var
  Window: TPreferencesWindow;
  Panes: array[0..6] of TOptionsPane;
  Index: Integer;
  Settings: TBrowserSettings;
  Help: THelpOpener;
begin
  Window := TPreferencesWindow.CreatePreferences('Options', PaneWidth, WindowHeight, Owner);
  Help := THelpOpener.Create;
  try
    Settings := BrowserApp.Settings;
    for Index := 0 to High(Classes) do
    begin
      Panes[Index] := Classes[Index].Create(Window.AddPane(Captions[Index], Icons[Index]), Window);
      Panes[Index].Build;
      Panes[Index].Load(Settings);
    end;
    Window.OnHelp := @Help.HelpClicked;
    if Pane < 0 then
      Pane := LastPane;
    Window.PaneIndex := Pane;
    Say('options open');
    Result := Window.Execute;
    LastPane := Window.PaneIndex;
    if Result then
    begin
      Settings := BrowserApp.Settings;
      for Index := 0 to High(Panes) do
        Panes[Index].Store(Settings);
      BrowserApp.Settings := Settings;
      BrowserApp.SaveSettings;
      BrowserApp.ApplySettings;
      Say('settings home ' + Settings.HomePage);
      Say('options saved');
    end;
  finally
    for Index := 0 to High(Panes) do
      Panes[Index].Free;
    Help.Free;
    Window.Free;
  end;
end;

end.

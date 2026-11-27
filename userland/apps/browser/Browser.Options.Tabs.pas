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
  Options > Tabs: new windows in a new tab, warnings when closing or
  opening several tabs, the tab bar always shown, switching to new tabs.
}
unit Browser.Options.Tabs;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Toggles,
  Browser.Settings,
  Browser.Options.Pane;

type
  TTabsPane = class(TOptionsPane)
  private
    FNewWindows: TCheckBox;
    FWarnClosing: TCheckBox;
    FWarnOpening: TCheckBox;
    FAlwaysShow: TCheckBox;
    FSwitchTo: TCheckBox;
  public
    procedure Build; override;
    procedure Load(constref Settings: TBrowserSettings); override;
    procedure Store(var Settings: TBrowserSettings); override;
  end;

implementation

procedure TTabsPane.Build;
begin
  FNewWindows := AddCheck(Page, 'Open new windows in a new ta&b instead', PaneMargin, 12);
  FWarnClosing := AddCheck(Page, '&Warn me when closing multiple tabs', PaneMargin, 12 + RowHeight);
  FWarnOpening := AddCheck(Page, 'Warn me when &opening multiple tabs might slow down Browser', PaneMargin,
    12 + 2 * RowHeight);
  FAlwaysShow := AddCheck(Page, 'Always show the tab &bar', PaneMargin, 12 + 3 * RowHeight);
  FSwitchTo := AddCheck(Page, 'When I open a link in a new tab, switch to it &immediately', PaneMargin,
    12 + 4 * RowHeight);
end;

procedure TTabsPane.Load(constref Settings: TBrowserSettings);
begin
  FNewWindows.Checked := Settings.NewWindowsInTabs;
  FWarnClosing.Checked := Settings.WarnClosingTabs;
  FWarnOpening.Checked := Settings.WarnOpeningTabs;
  FAlwaysShow.Checked := Settings.AlwaysShowTabBar;
  FSwitchTo.Checked := Settings.SwitchToNewTabs;
end;

procedure TTabsPane.Store(var Settings: TBrowserSettings);
begin
  Settings.NewWindowsInTabs := FNewWindows.Checked;
  Settings.WarnClosingTabs := FWarnClosing.Checked;
  Settings.WarnOpeningTabs := FWarnOpening.Checked;
  Settings.AlwaysShowTabBar := FAlwaysShow.Checked;
  Settings.SwitchToNewTabs := FSwitchTo.Checked;
end;

end.

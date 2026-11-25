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
  Options > Advanced, in tabs:
  - General: accessibility (cursor keys to move in pages, search for
    text as you type), browsing (smooth scrolling, spelling as you
    type: kept for when there is a dictionary);
  - Network: Connection (Settings...: how the browser reaches the
    network), HTTP/3, and the cache (its size, what it holds now, Clear
    Now);
  - Update: checking for updates (the system updates the browser; kept);
  - Encryption: the protocols offered, and View Certificates (libtls's
    trust store).
}
unit Browser.Options.Advanced;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Labels,
  Controls.Toggles,
  Controls.NumericUpDown,
  Controls.TabControl,
  Browser.Settings,
  Browser.Options.Pane;

type
  TAdvancedPane = class(TOptionsPane)
  private
    FTabs: TTabControl;
    FCaretBrowsing: TCheckBox;
    FSearchTyping: TCheckBox;
    FSmooth: TCheckBox;
    FSpelling: TCheckBox;
    FHttp3: TCheckBox;
    FCacheSize: TNumericUpDown;
    FCacheUse: TLabel;
    FCheckUpdates: TCheckBox;
    FSsl3: TCheckBox;
    FTls1: TCheckBox;
    FProxyMode: TProxyMode;
    FProxyHost: string;
    FProxyPort: LongInt;
    FNoProxyFor: string;
    procedure ConnectionClicked(Sender: TControl);
    procedure ClearCacheClicked(Sender: TControl);
    procedure CertificatesClicked(Sender: TControl);
    procedure ShowCacheUse;
  public
    procedure Build; override;
    procedure Load(constref Settings: TBrowserSettings); override;
    procedure Store(var Settings: TBrowserSettings); override;
  end;

implementation

uses
  SysUtils,
  WebView.Network,
  Browser.Downloads,
  Browser.Options.Dialogs;

procedure TAdvancedPane.Build;
var
  Tab, Group: TControl;
begin
  FTabs := TTabControl.Create(Page);
  FTabs.SetBounds(PaneMargin, 8, PaneWidth - 2 * PaneMargin, 330);
  FTabs.Anchors := [akLeft, akTop, akRight, akBottom];
  Tab := FTabs.AddPage('General');
  Group := AddGroupIn(Tab, 'Accessibility', 8, 72);
  FCaretBrowsing := AddCheck(Group, 'Always use the &cursor keys to navigate within pages', 10, GroupTop);
  FSearchTyping := AddCheck(Group, 'Search for text when I start &typing', 10, GroupTop + 22);
  Group := AddGroupIn(Tab, 'Browsing', 88, 72);
  FSmooth := AddCheck(Group, 'Use s&mooth scrolling', 10, GroupTop);
  FSpelling := AddCheck(Group, 'Check my s&pelling as I type', 10, GroupTop + 22);
  Tab := FTabs.AddPage('Network');
  Group := AddGroupIn(Tab, 'Connection', 8, 84);
  AddLabel(Group, 'Configure how Browser connects to the Internet', 10, GroupTop, 330);
  AddButton(Group, 'Se&ttings...', 400, GroupTop, 100, @ConnectionClicked);
  FHttp3 := AddCheck(Group, 'Use HTTP/&3 where a site offers it', 10, GroupTop + 28);
  Group := AddGroupIn(Tab, 'Offline Storage', 100, 84);
  FCacheUse := AddLabel(Group, 'Your cache is using 0 bytes', 10, GroupTop, 330);
  AddButton(Group, 'Clear &Now', 400, GroupTop, 100, @ClearCacheClicked);
  AddLabel(Group, '&Use up to', 10, GroupTop + 28, 80);
  FCacheSize := TNumericUpDown.Create(Group);
  FCacheSize.SetBounds(90, GroupTop + 28, 80, 22);
  FCacheSize.Minimum := 0;
  FCacheSize.Maximum := 1024;
  AddLabel(Group, 'MB of space for the cache', 176, GroupTop + 28, 200);
  Tab := FTabs.AddPage('Update');
  Group := AddGroupIn(Tab, 'Automatically check for updates to', 8, 84);
  FCheckUpdates := AddCheck(Group, '&Browser', 10, GroupTop);
  AddLabel(Group, 'Browser is updated with the system itself.', 10, GroupTop + 26, 400);
  Tab := FTabs.AddPage('Encryption');
  Group := AddGroupIn(Tab, 'Protocols', 8, 72);
  FSsl3 := AddCheck(Group, 'Use SSL &3.0', 10, GroupTop);
  FTls1 := AddCheck(Group, 'Use TLS &1.0', 200, GroupTop);
  AddLabel(Group, 'TLS 1.2 and 1.3 are always used.', 10, GroupTop + 22, 300);
  Group := AddGroupIn(Tab, 'Certificates', 88, 64);
  AddButton(Group, 'View &Certificates', 10, GroupTop, 150, @CertificatesClicked);
  FTabs.PageIndex := 0;
end;

procedure TAdvancedPane.ShowCacheUse;
begin
  FCacheUse.Text := 'Your cache is using ' + SizeText(HttpCacheBytes) + ' of space';
end;

procedure TAdvancedPane.Load(constref Settings: TBrowserSettings);
begin
  FCaretBrowsing.Checked := Settings.CaretBrowsing;
  FSearchTyping.Checked := Settings.SearchWhenTyping;
  FSmooth.Checked := Settings.SmoothScrolling;
  FSpelling.Checked := Settings.CheckSpelling;
  FHttp3.Checked := Settings.Http3;
  FCacheSize.Value := Settings.CacheMegabytes;
  FCheckUpdates.Checked := Settings.CheckUpdates;
  FSsl3.Checked := Settings.Ssl3;
  FTls1.Checked := Settings.Tls1;
  FProxyMode := Settings.ProxyMode;
  FProxyHost := Settings.ProxyHost;
  FProxyPort := Settings.ProxyPort;
  FNoProxyFor := Settings.NoProxyFor;
  ShowCacheUse;
end;

procedure TAdvancedPane.Store(var Settings: TBrowserSettings);
begin
  Settings.CaretBrowsing := FCaretBrowsing.Checked;
  Settings.SearchWhenTyping := FSearchTyping.Checked;
  Settings.SmoothScrolling := FSmooth.Checked;
  Settings.CheckSpelling := FSpelling.Checked;
  Settings.Http3 := FHttp3.Checked;
  Settings.CacheMegabytes := Round(FCacheSize.Value);
  Settings.CheckUpdates := FCheckUpdates.Checked;
  Settings.Ssl3 := FSsl3.Checked;
  Settings.Tls1 := FTls1.Checked;
  Settings.ProxyMode := FProxyMode;
  Settings.ProxyHost := FProxyHost;
  Settings.ProxyPort := FProxyPort;
  Settings.NoProxyFor := FNoProxyFor;
end;

procedure TAdvancedPane.ConnectionClicked(Sender: TControl);
begin
  EditConnectionSettings(Owner, FProxyMode, FProxyHost, FProxyPort, FNoProxyFor);
end;

procedure TAdvancedPane.ClearCacheClicked(Sender: TControl);
begin
  ClearHttpCache;
  ShowCacheUse;
end;

procedure TAdvancedPane.CertificatesClicked(Sender: TControl);
begin
  ShowCertificates(Owner);
end;

end.

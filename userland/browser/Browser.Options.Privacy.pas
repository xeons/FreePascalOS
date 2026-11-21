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
  Options > Privacy: whether the history is remembered (always, never,
  or custom settings: private browsing always, browsing, download and
  form history, cookies with their exceptions and Show Cookies..., how
  long cookies are kept, clearing history when the browser closes, with
  what to clear), and what the location bar suggests.
}
unit Browser.Options.Privacy;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Panels,
  Controls.Labels,
  Controls.Toggles,
  Controls.ComboBox,
  Browser.Settings,
  Browser.Options.Pane;

type
  TPrivacyPane = class(TOptionsPane)
  private
    FHistoryMode: TComboBox;
    FCustom: TPanel;
    FExplanation: TLabel;
    FExplanation2: TLabel;
    FAlwaysPrivate: TCheckBox;
    FRememberHistory: TCheckBox;
    FRememberDownloads: TCheckBox;
    FRememberForms: TCheckBox;
    FAcceptCookies: TCheckBox;
    FThirdParty: TCheckBox;
    FKeepUntil: TComboBox;
    FClearOnClose: TCheckBox;
    FSuggest: TComboBox;
    FAllowed, FBlocked: string;
    FClearItems: string;
    procedure ModeChanged(Sender: TControl);
    procedure ExceptionsClicked(Sender: TControl);
    procedure ShowCookiesClicked(Sender: TControl);
    procedure ClearSettingsClicked(Sender: TControl);
  public
    procedure Build; override;
    procedure Load(constref Settings: TBrowserSettings); override;
    procedure Store(var Settings: TBrowserSettings); override;
  end;

implementation

uses
  Browser.Options.Dialogs,
  Browser.ClearHistory;

procedure TPrivacyPane.Build;
var
  Group: TControl;
begin
  Group := AddGroup('History', 8, 268);
  AddLabel(Group, 'Browser &will:', 10, GroupTop, 90);
  FHistoryMode := AddCombo(Group, ['Remember history', 'Never remember history', 'Use custom settings for history'],
    100, GroupTop, 260);
  FHistoryMode.OnChange := @ModeChanged;
  FExplanation := AddLabel(Group, '', 10, GroupTop + 34, PaneWidth - 60);
  FExplanation2 := AddLabel(Group, '', 10, GroupTop + 54, PaneWidth - 60);
  FCustom := AddRadioPanel(Group, 10, GroupTop + 28, PaneWidth - 50, 204);
  FAlwaysPrivate := AddCheck(FCustom, 'Automatically start Browser in a &private browsing session', 0, 0);
  FRememberHistory := AddCheck(FCustom, 'Remember my &browsing history', 16, 22);
  FRememberDownloads := AddCheck(FCustom, 'Remember &download history', 16, 44);
  FRememberForms := AddCheck(FCustom, 'Remember search and &form history', 16, 66);
  FAcceptCookies := AddCheck(FCustom, 'Accept &cookies from sites', 16, 88);
  AddButton(FCustom, '&Exceptions...', 380, 86, 110, @ExceptionsClicked);
  FThirdParty := AddCheck(FCustom, 'Accept &third-party cookies', 36, 110);
  AddLabel(FCustom, '&Keep until:', 36, 134, 80);
  FKeepUntil := AddCombo(FCustom, ['they expire', 'I close Browser', 'ask me every time'], 120, 134, 160);
  AddButton(FCustom, 'Show Coo&kies...', 380, 134, 110, @ShowCookiesClicked);
  FClearOnClose := AddCheck(FCustom, 'C&lear history when Browser closes', 16, 164);
  AddButton(FCustom, 'Se&ttings...', 380, 162, 110, @ClearSettingsClicked);
  Group := AddGroup('Location Bar', 284, 60);
  AddLabel(Group, 'When using the location bar, &suggest:', 10, GroupTop, 240);
  FSuggest := AddCombo(Group, ['History and Bookmarks', 'History', 'Bookmarks', 'Nothing'], 260, GroupTop, 200);
end;

procedure TPrivacyPane.ModeChanged(Sender: TControl);
begin
  FCustom.Visible := FHistoryMode.ItemIndex = Ord(HistoryCustom);
  case FHistoryMode.ItemIndex of
    Ord(HistoryRemember):
      begin
        FExplanation.Text := 'Browser will remember your browsing, download, form and search history,';
        FExplanation2.Text := 'and keep cookies from web sites you visit.';
      end;
    Ord(HistoryNever):
      begin
        FExplanation.Text := 'Browser will use the same settings as private browsing, and will not';
        FExplanation2.Text := 'remember any history as you browse the Web.';
      end;
  else
    begin
      FExplanation.Text := '';
      FExplanation2.Text := '';
    end;
  end;
end;

procedure TPrivacyPane.Load(constref Settings: TBrowserSettings);
begin
  FHistoryMode.ItemIndex := Ord(Settings.History);
  FAlwaysPrivate.Checked := Settings.AlwaysPrivate;
  FRememberHistory.Checked := Settings.RememberHistory;
  FRememberDownloads.Checked := Settings.RememberDownloads;
  FRememberForms.Checked := Settings.RememberForms;
  FAcceptCookies.Checked := Settings.AcceptCookies;
  FThirdParty.Checked := Settings.ThirdPartyCookies;
  FKeepUntil.ItemIndex := Ord(Settings.KeepCookies);
  FClearOnClose.Checked := Settings.ClearOnClose;
  FSuggest.ItemIndex := Ord(Settings.LocationSuggest);
  FAllowed := Settings.CookiesAllowed;
  FBlocked := Settings.CookiesBlocked;
  FClearItems := Settings.ClearItems;
  ModeChanged(nil);
end;

procedure TPrivacyPane.Store(var Settings: TBrowserSettings);
begin
  Settings.History := THistoryMode(FHistoryMode.ItemIndex);
  Settings.AlwaysPrivate := FAlwaysPrivate.Checked and (Settings.History = HistoryCustom);
  Settings.RememberHistory := FRememberHistory.Checked;
  Settings.RememberDownloads := FRememberDownloads.Checked;
  Settings.RememberForms := FRememberForms.Checked;
  Settings.AcceptCookies := FAcceptCookies.Checked;
  Settings.ThirdPartyCookies := FThirdParty.Checked;
  Settings.KeepCookies := TKeepCookies(FKeepUntil.ItemIndex);
  Settings.ClearOnClose := FClearOnClose.Checked;
  Settings.LocationSuggest := TLocationSuggest(FSuggest.ItemIndex);
  Settings.CookiesAllowed := FAllowed;
  Settings.CookiesBlocked := FBlocked;
  Settings.ClearItems := FClearItems;
end;

procedure TPrivacyPane.ExceptionsClicked(Sender: TControl);
begin
  EditCookieExceptions(Owner, FAllowed, FBlocked);
end;

procedure TPrivacyPane.ShowCookiesClicked(Sender: TControl);
begin
  ShowCookies(Owner);
end;

procedure TPrivacyPane.ClearSettingsClicked(Sender: TControl);
begin
  ChooseClearItems(Owner, FClearItems);
end;

end.

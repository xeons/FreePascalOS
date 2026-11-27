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
  Options > Security: warnings about add-ons, reported attack sites and
  forgeries (kept as settings; there are no add-ons and no online lists
  yet), and passwords: whether they are remembered, and Saved
  Passwords... (the browser's own list, Browser.Passwords).
}
unit Browser.Options.Security;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Toggles,
  Browser.Settings,
  Browser.Options.Pane;

type
  TSecurityPane = class(TOptionsPane)
  private
    FWarnAddons: TCheckBox;
    FBlockAttacks: TCheckBox;
    FBlockForgeries: TCheckBox;
    FRememberPasswords: TCheckBox;
    procedure SavedPasswordsClicked(Sender: TControl);
  public
    procedure Build; override;
    procedure Load(constref Settings: TBrowserSettings); override;
    procedure Store(var Settings: TBrowserSettings); override;
  end;

implementation

uses
  Browser.Options.Dialogs;

procedure TSecurityPane.Build;
var
  Group: TControl;
begin
  FWarnAddons := AddCheck(Page, '&Warn me when sites try to install add-ons', PaneMargin, 12);
  FBlockAttacks := AddCheck(Page, 'Block reported &attack sites', PaneMargin, 12 + RowHeight);
  FBlockForgeries := AddCheck(Page, 'Block reported web &forgeries', PaneMargin, 12 + 2 * RowHeight);
  AddLabel(Page, '(No list of reported sites is fetched: the browser sends nothing anyone did not ask for.)',
    PaneMargin + 20, 12 + 3 * RowHeight, 500);
  Group := AddGroup('Passwords', 120, 64);
  FRememberPasswords := AddCheck(Group, '&Remember passwords for sites', 10, GroupTop);
  AddButton(Group, '&Saved Passwords...', 380, GroupTop, 140, @SavedPasswordsClicked);
end;

procedure TSecurityPane.Load(constref Settings: TBrowserSettings);
begin
  FWarnAddons.Checked := Settings.WarnAddons;
  FBlockAttacks.Checked := Settings.BlockAttackSites;
  FBlockForgeries.Checked := Settings.BlockForgeries;
  FRememberPasswords.Checked := Settings.RememberPasswords;
end;

procedure TSecurityPane.Store(var Settings: TBrowserSettings);
begin
  Settings.WarnAddons := FWarnAddons.Checked;
  Settings.BlockAttackSites := FBlockAttacks.Checked;
  Settings.BlockForgeries := FBlockForgeries.Checked;
  Settings.RememberPasswords := FRememberPasswords.Checked;
end;

procedure TSecurityPane.SavedPasswordsClicked(Sender: TControl);
begin
  ShowSavedPasswords(Owner);
end;

end.

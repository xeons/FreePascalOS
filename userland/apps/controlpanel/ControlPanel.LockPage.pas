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
  The Screen Lock page: whether the screen locks by itself after some
  minutes without input (off at first), and whether it is locked when
  the computer wakes from suspend. Applying keeps them in the user's
  settings (Windowing.LockSettings), where the session manager looks for
  them.
}
unit ControlPanel.LockPage;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Labels,
  Controls.Toggles,
  Controls.ComboBox,
  ControlPanel.Pages;

type
  TLockPage = class(TSettingsPage)
  private
    FAfterIdle: TCheckBox;
    FMinutes: TComboBox;
    FOnResume: TCheckBox;
    procedure AfterIdleChanged(Sender: TControl);
  protected
    procedure LoadSettings; override;
  public
    constructor CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string); override;
    function PageName: string; override;
    function Apply: Boolean; override;
    procedure TellPlaces; override;
  end;

implementation

uses
  SysUtils,
  Configuration.Settings,
  Configuration.Locations,
  Windowing.LockSettings,
  Controls.MessageBoxes,
  ControlPanel.Report;

const
  { The waits offered, in minutes. }
  MinuteChoices: array[0..7] of LongWord = (1, 2, 3, 5, 10, 15, 30, 60);
  { What a new choice starts at. }
  DefaultChoice = 4;
  OnOff: array[Boolean] of string = ('off', 'on');

function MinutesText(Minutes: LongWord): string;
begin
  if Minutes = 1 then
    Result := '1 minute'
  else
    Result := IntToStr(Minutes) + ' minutes';
end;

constructor TLockPage.CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string);
var
  Caption: TLabel;
  Index: LongInt;
begin
  inherited CreatePage(AParent, AWindow, ATitle);
  FAfterIdle := TCheckBox.Create(Self);
  FAfterIdle.Text := 'Lock the screen when it has not been used for:';
  FAfterIdle.SetBounds(PageMargin, 30, PageWidth - 2 * PageMargin, 20);
  FAfterIdle.OnChange := @AfterIdleChanged;
  FMinutes := TComboBox.Create(Self);
  FMinutes.SetBounds(PageMargin + 24, 56, 150, RowHeight);
  for Index := Low(MinuteChoices) to High(MinuteChoices) do
    FMinutes.Items.Add(MinutesText(MinuteChoices[Index]));
  FMinutes.OnChange := @ControlChanged;
  FOnResume := TCheckBox.Create(Self);
  FOnResume.Text := 'Lock the screen when the computer &wakes from suspend';
  FOnResume.SetBounds(PageMargin, 100, PageWidth - 2 * PageMargin, 20);
  FOnResume.OnChange := @ControlChanged;
  Caption := TLabel.Create(Self);
  Caption.Text := 'Super+L or Ctrl+Alt+L locks the screen at any time.';
  Caption.SetBounds(PageMargin, 140, PageWidth - 2 * PageMargin, 18);
end;

function TLockPage.PageName: string;
begin
  Result := 'lock';
end;

procedure TLockPage.AfterIdleChanged(Sender: TControl);
begin
  FMinutes.Enabled := FAfterIdle.Checked;
  MarkModified;
end;

{ The choice nearest to Minutes (at or above it). }
function ChoiceOf(Minutes: LongWord): LongInt;
begin
  Result := Low(MinuteChoices);
  while (Result < High(MinuteChoices)) and (MinuteChoices[Result] < Minutes) do
    Inc(Result);
end;

procedure TLockPage.LoadSettings;
var
  Store: TSettings;
  Settings: TLockSettings;
begin
  Store := OpenSettings;
  Settings := RememberedLockSettings(Store);
  Store.Free;
  FAfterIdle.Checked := Settings.AfterMinutes > 0;
  if Settings.AfterMinutes > 0 then
    FMinutes.ItemIndex := ChoiceOf(Settings.AfterMinutes)
  else
    FMinutes.ItemIndex := DefaultChoice;
  FMinutes.Enabled := FAfterIdle.Checked;
  FOnResume.Checked := Settings.OnResume;
end;

function TLockPage.Apply: Boolean;
var
  Store: TSettings;
  Settings: TLockSettings;
begin
  Settings.AfterMinutes := 0;
  if FAfterIdle.Checked and (FMinutes.ItemIndex >= 0) then
    Settings.AfterMinutes := MinuteChoices[FMinutes.ItemIndex];
  Settings.OnResume := FOnResume.Checked;
  Store := OpenSettings;
  Result := Store.HasScope(ScopeUser);
  if Result then
  begin
    RememberLockSettings(Store, Settings);
    Store.Flush;
  end;
  Store.Free;
  if not Result then
  begin
    ShowMessageBox('Screen Lock', 'There is no home folder to keep your settings in.', MessageOk, SignError, Window);
    Exit;
  end;
  Say(Format('applied lock after %d minutes, on resume %s', [Settings.AfterMinutes, OnOff[Settings.OnResume]]));
  inherited Apply;
end;

procedure TLockPage.TellPlaces;
begin
  SayControlPlace('lock-after-idle', Window, FAfterIdle);
  SayControlPlace('lock-minutes', Window, FMinutes);
  SayControlPlace('lock-on-resume', Window, FOnResume);
end;

end.

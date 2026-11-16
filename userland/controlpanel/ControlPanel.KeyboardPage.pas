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
  The Keyboard page: the layout (the kernel's tables: US, UK, German,
  French), the delay before a held key repeats and how fast it then
  repeats, and a box to try them in. Applying gives them to the display
  server (which asks the kernel: the next key typed anywhere uses them)
  and keeps them in the user's settings (Windowing.KeyboardSettings),
  where the session manager finds them at the next login.
}
unit ControlPanel.KeyboardPage;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Sys.Keyboard,
  Controls.Base,
  Controls.Window,
  Controls.Labels,
  Controls.ListBox,
  Controls.EditBox,
  Controls.Slider,
  ControlPanel.Pages;

type
  TKeyboardPage = class(TSettingsPage)
  private
    FLayouts: TListBox;
    FLayoutNames: array of string;
    FDelay: TSlider;
    FDelayValue: TLabel;
    FRate: TSlider;
    FRateValue: TLabel;
    FTryBox: TEditBox;
    procedure SliderChanged(Sender: TControl);
    procedure TryBoxChanged(Sender: TControl);
    procedure ShowValues;
    procedure ShowSettings(const Settings: TKeyboardSettings);
  protected
    procedure LoadSettings; override;
    procedure ReloadSettings(const Group: string); override;
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
  Windowing.Connection,
  Windowing.KeyboardSettings,
  Configuration.Settings,
  Configuration.Locations,
  Controls.MessageBoxes,
  ControlPanel.Report;

const
  SliderLeft = PageMargin + LabelWidth;
  SliderWidth = 200;
  { The delay goes in quarter seconds, what PS/2 keyboards can do. }
  DelayStep = 250;

constructor TKeyboardPage.CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string);
var
  Caption: TLabel;
  Index: Integer;
  Description: TKeyboardLayoutDescription;
begin
  inherited CreatePage(AParent, AWindow, ATitle);
  Caption := TLabel.Create(Self);
  Caption.Text := '&Layout:';
  Caption.SetBounds(PageMargin, 30, LabelWidth - 6, 18);
  FLayouts := TListBox.Create(Self);
  FLayouts.SetBounds(SliderLeft, 28, PageWidth - SliderLeft - PageMargin, 96);
  Index := 0;
  while DescribeKeyboardLayout(Index, Description) do
  begin
    SetLength(FLayoutNames, Index + 1);
    FLayoutNames[Index] := Description.Name;
    FLayouts.Items.Add(Description.Description);
    Inc(Index);
  end;
  FLayouts.OnChange := @ControlChanged;
  Caption := TLabel.Create(Self);
  Caption.Text := 'Repeat &delay:';
  Caption.SetBounds(PageMargin, 142, LabelWidth - 6, 18);
  FDelay := TSlider.Create(Self);
  FDelay.SetBounds(SliderLeft, 140, SliderWidth, 30);
  FDelay.SetRange(MinimumKeyRepeatDelay div DelayStep, MaximumKeyRepeatDelay div DelayStep);
  FDelay.TickStep := 1;
  FDelay.PageStep := 1;
  FDelay.OnChange := @SliderChanged;
  FDelayValue := TLabel.Create(Self);
  FDelayValue.SetBounds(SliderLeft + SliderWidth + 10, 142, 90, 18);
  Caption := TLabel.Create(Self);
  Caption.Text := 'Repeat &rate:';
  Caption.SetBounds(PageMargin, 186, LabelWidth - 6, 18);
  FRate := TSlider.Create(Self);
  FRate.SetBounds(SliderLeft, 184, SliderWidth, 30);
  FRate.SetRange(MinimumKeyRepeatRate, MaximumKeyRepeatRate);
  FRate.TickStep := 4;
  FRate.PageStep := 4;
  FRate.OnChange := @SliderChanged;
  FRateValue := TLabel.Create(Self);
  FRateValue.SetBounds(SliderLeft + SliderWidth + 10, 186, 90, 18);
  Caption := TLabel.Create(Self);
  Caption.Text := '&Try them here:';
  Caption.SetBounds(PageMargin, 234, LabelWidth - 6, 18);
  FTryBox := TEditBox.Create(Self);
  FTryBox.SetBounds(SliderLeft, 232, PageWidth - SliderLeft - PageMargin, 22);
  FTryBox.OnChange := @TryBoxChanged;
end;

procedure TKeyboardPage.TryBoxChanged(Sender: TControl);
begin
  { What the keys typed, so a test can see the layout at work. }
  Say('typed ' + FTryBox.Text);
end;

function TKeyboardPage.SettingsGroups: TStringArray;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := 'Keyboard';
end;

function TKeyboardPage.PageName: string;
begin
  Result := 'keyboard';
end;

procedure TKeyboardPage.ShowValues;
begin
  FDelayValue.Text := IntToStr(FDelay.Position * DelayStep) + ' ms';
  FRateValue.Text := IntToStr(FRate.Position) + ' a second';
end;

procedure TKeyboardPage.SliderChanged(Sender: TControl);
begin
  ShowValues;
  MarkModified;
end;

procedure TKeyboardPage.LoadSettings;
var
  Settings: TKeyboardSettings;
begin
  AskKeyboardSettings(Settings);
  ShowSettings(Settings);
end;

{ Changed elsewhere: what the user's settings say now, which the session
  manager gives the display server (it may not have them yet). }
procedure TKeyboardPage.ReloadSettings(const Group: string);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  ShowSettings(RememberedKeyboardSettings(Store));
  Store.Free;
end;

procedure TKeyboardPage.ShowSettings(const Settings: TKeyboardSettings);
var
  Index: Integer;
begin
  for Index := 0 to High(FLayoutNames) do
    if FLayoutNames[Index] = Settings.Layout then
      FLayouts.ItemIndex := Index;
  FDelay.Position := (Settings.RepeatDelay + DelayStep div 2) div DelayStep;
  FRate.Position := Settings.RepeatRate;
  ShowValues;
end;

function TKeyboardPage.Apply: Boolean;
var
  Wanted: TKeyboardSettings;
  Applied: TKeyboardSettings;
  Store: TSettings;
begin
  Result := True;
  if FLayouts.ItemIndex < 0 then
    Exit;
  Wanted := NewKeyboardSettings(FLayoutNames[FLayouts.ItemIndex]);
  Wanted.RepeatDelay := FDelay.Position * DelayStep;
  Wanted.RepeatRate := FRate.Position;
  Result := ChangeKeyboardSettings(Wanted, Applied);
  if not Result then
  begin
    ShowMessageBox('Keyboard', 'The display server did not take the keyboard settings.', MessageOk, SignError,
      Window);
    Exit;
  end;
  Store := OpenSettings;
  if Store.HasScope(ScopeUser) then
  begin
    RememberKeyboardSettings(Store, Applied);
    Store.Flush;
  end;
  Store.Free;
  Say(Format('applied keyboard layout %s, repeat delay %d, rate %d', [Applied.Layout,
    Applied.RepeatDelay, Applied.RepeatRate]));
  inherited Apply;
end;

procedure TKeyboardPage.TellPlaces;
var
  Index: Integer;
  RowMiddle: LongInt;
begin
  for Index := 0 to High(FLayoutNames) do
  begin
    RowMiddle := 2 + Index * FLayouts.ItemHeight + FLayouts.ItemHeight div 2;
    SayPlace('keyboard-layout-' + FLayoutNames[Index], Window, FLayouts, Scaled(40), RowMiddle);
  end;
  SayControlPlace('keyboard-try', Window, FTryBox);
end;

end.

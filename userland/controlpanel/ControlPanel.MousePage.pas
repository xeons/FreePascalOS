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
  The Mouse page: the pointer's speed and acceleration (a slider and a
  numeric up/down box each, kept together), and left-handed buttons. Applying gives them to the display server and keeps them in
  the user's settings (Windowing.MouseSettings), where the session
  manager finds them at the next login.
}
unit ControlPanel.MousePage;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Windowing.MouseSettings,
  Controls.Base,
  Controls.Window,
  Controls.Labels,
  Controls.Toggles,
  Controls.Slider,
  Controls.NumericUpDown,
  ControlPanel.Pages;

type
  TMousePage = class(TSettingsPage)
  private
    FSpeed: TSlider;
    FSpeedValue: TNumericUpDown;
    FAcceleration: TSlider;
    FAccelerationValue: TNumericUpDown;
    FLeftHanded: TCheckBox;
    procedure SliderChanged(Sender: TControl);
    procedure ValueBoxChanged(Sender: TControl);
    procedure ShowValues;
    procedure ShowSettings(const Settings: TMouseSettings);
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
  Windowing.Protocol,
  Windowing.Connection,
  Configuration.Settings,
  Configuration.Locations,
  Controls.MessageBoxes,
  ControlPanel.Report;

const
  OnOff: array[Boolean] of string = ('off', 'on');
  SliderLeft = PageMargin + LabelWidth;
  SliderWidth = 220;

constructor TMousePage.CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string);
var
  Caption: TLabel;
begin
  inherited CreatePage(AParent, AWindow, ATitle);
  Caption := TLabel.Create(Self);
  Caption.Text := 'Pointer &speed:';
  Caption.SetBounds(PageMargin, 32, LabelWidth - 6, 18);
  FSpeed := TSlider.Create(Self);
  FSpeed.SetBounds(SliderLeft, 30, SliderWidth, 30);
  FSpeed.SetRange(MinimumMouseSpeed, MaximumMouseSpeed);
  FSpeed.TickStep := 1;
  FSpeed.PageStep := 5;
  FSpeed.OnChange := @SliderChanged;
  FSpeedValue := TNumericUpDown.Create(Self);
  FSpeedValue.SetBounds(SliderLeft + SliderWidth + 10, 34, 56, 22);
  FSpeedValue.SetRange(MinimumMouseSpeed, MaximumMouseSpeed);
  FSpeedValue.OnValueChanged := @ValueBoxChanged;
  Caption := TLabel.Create(Self);
  Caption.Text := '&Acceleration:';
  Caption.SetBounds(PageMargin, 80, LabelWidth - 6, 18);
  FAcceleration := TSlider.Create(Self);
  FAcceleration.SetBounds(SliderLeft, 78, SliderWidth, 30);
  FAcceleration.SetRange(0, MaximumMouseAcceleration);
  FAcceleration.TickStep := 1;
  FAcceleration.PageStep := 2;
  FAcceleration.OnChange := @SliderChanged;
  FAccelerationValue := TNumericUpDown.Create(Self);
  FAccelerationValue.SetBounds(SliderLeft + SliderWidth + 10, 82, 56, 22);
  FAccelerationValue.SetRange(0, MaximumMouseAcceleration);
  FAccelerationValue.OnValueChanged := @ValueBoxChanged;
  FLeftHanded := TCheckBox.Create(Self);
  FLeftHanded.Text := 'Switch the &left and right buttons (left-handed)';
  FLeftHanded.SetBounds(PageMargin, 128, PageWidth - 2 * PageMargin, 20);
  FLeftHanded.OnChange := @ControlChanged;
end;

function TMousePage.SettingsGroups: TStringArray;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := 'Mouse';
end;

function TMousePage.PageName: string;
begin
  Result := 'mouse';
end;

procedure TMousePage.ShowValues;
begin
  FSpeedValue.Value := FSpeed.Position;
  FAccelerationValue.Value := FAcceleration.Position;
end;

procedure TMousePage.SliderChanged(Sender: TControl);
begin
  ShowValues;
  MarkModified;
end;

{ A value typed or stepped moves its slider (which marks the page
  modified). }
procedure TMousePage.ValueBoxChanged(Sender: TControl);
begin
  if Sender = FSpeedValue then
    FSpeed.Position := FSpeedValue.IntegerValue
  else
    FAcceleration.Position := FAccelerationValue.IntegerValue;
end;

procedure TMousePage.LoadSettings;
var
  Settings: TMouseSettings;
begin
  AskMouseSettings(Settings);
  ShowSettings(Settings);
end;

{ Changed elsewhere: what the user's settings say now, which the session
  manager gives the display server (it may not have them yet). }
procedure TMousePage.ReloadSettings(const Group: string);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  ShowSettings(RememberedMouseSettings(Store));
  Store.Free;
end;

procedure TMousePage.ShowSettings(const Settings: TMouseSettings);
begin
  FSpeed.Position := Settings.Speed;
  FAcceleration.Position := Settings.Acceleration;
  FLeftHanded.Checked := Settings.LeftHanded;
  ShowValues;
end;

function TMousePage.Apply: Boolean;
var
  Wanted: TMouseSettings;
  Applied: TMouseSettings;
  Store: TSettings;
begin
  Wanted.Speed := FSpeed.Position;
  Wanted.Acceleration := FAcceleration.Position;
  Wanted.LeftHanded := FLeftHanded.Checked;
  Result := ChangeMouseSettings(Wanted, Applied);
  if not Result then
  begin
    ShowMessageBox('Mouse', 'The display server did not take the mouse settings.', MessageOk, SignError, Window);
    Exit;
  end;
  Store := OpenSettings;
  if Store.HasScope(ScopeUser) then
  begin
    RememberMouseSettings(Store, Applied);
    Store.Flush;
  end;
  Store.Free;
  Say(Format('applied mouse speed %d, acceleration %d, left-handed %s', [Applied.Speed, Applied.Acceleration,
    OnOff[Applied.LeftHanded]]));
  inherited Apply;
end;

procedure TMousePage.TellPlaces;
const
  Speeds: array[0..4] of LongInt = (1, 5, 10, 15, 20);
var
  Index: LongInt;
begin
  for Index := Low(Speeds) to High(Speeds) do
    SayPlace('mouse-speed-' + IntToStr(Speeds[Index]), Window, FSpeed, FSpeed.PixelOfValue(Speeds[Index]),
      Scaled(10));
  SayControlPlace('mouse-left-handed', Window, FLeftHanded);
end;

end.

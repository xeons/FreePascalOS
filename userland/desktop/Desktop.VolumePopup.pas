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
  The volume control the volume icon opens: a small pop-up above the
  taskbar with the default output's volume on a slider, Mute, and a
  button that opens the Control Panel's Sound page.

  The slider and Mute act at once on the output (Audio.Outputs: anyone
  may); when the pop-up closes, a change is kept for the next boot by
  the system settings service. A press outside it closes it, like a
  menu. It says "volume-popup" when it opens, where its parts are
  ("place volume-N X Y", "place volume-mute X Y", "place
  volume-settings X Y"), "volume N" and "mute on|off" as they change
  and "volume-kept N" when the change is kept.
}
unit Desktop.VolumePopup;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Popups,
  Controls.Labels,
  Controls.Toggles,
  Controls.Buttons,
  Controls.Panels,
  Controls.Slider;

type
  TVolumePopup = class(TPopupWindow)
  private
    FOutput: LongInt;
    FValue: TLabel;
    FSlider: TSlider;
    FMute: TCheckBox;
    FSettingsButton: TButton;
    FChanged: Boolean;
    procedure SliderChanged(Sender: TControl);
    procedure MuteChanged(Sender: TControl);
    procedure SettingsClicked(Sender: TControl);
    procedure Closed(Sender: TControl);
    procedure KeepChange;
  public
    { Above the point (Left, Bottom) of the screen, logical units. }
    constructor CreateVolumePopup(AOwner: TControlWindow; Left, Bottom: LongInt);
    procedure Open;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Windowing.Connection,
  Windowing.Displays,
  Sys.SystemSettings,
  Audio.Outputs,
  Controls.Text,
  Desktop.Programs,
  Desktop.Report;

const
  PopupWidth = 220;
  PopupHeight = 112;
  Margin = 10;

constructor TVolumePopup.CreateVolumePopup(AOwner: TControlWindow; Left, Bottom: LongInt);
var
  Top: LongInt;
  Frame: TPanel;
  Caption: TLabel;
  State: TAudioOutputState;
  HasOutput: Boolean;
begin
  Left := Left - PopupWidth div 2;
  Top := Bottom - PopupHeight;
  KeepOnDisplay(Left, Top, PopupWidth, PopupHeight);
  inherited CreatePopup(AOwner, Left, Top, PopupWidth, PopupHeight);
  FOutput := DefaultAudioOutput;
  HasOutput := DescribeAudioOutput(FOutput, State);
  { A raised edge, as a menu has, sets it off from what is behind. }
  Frame := TPanel.Create(Root);
  Frame.Edge := PanelRaised;
  Frame.Align := AlignClient;
  Caption := TLabel.Create(Root);
  Caption.ShowsMnemonic := False;
  Caption.Text := 'Volume';
  Caption.SetBounds(Margin, Margin, 100, 18);
  FValue := TLabel.Create(Root);
  FValue.ShowsMnemonic := False;
  FValue.Alignment := AlignTextRight;
  FValue.SetBounds(PopupWidth - Margin - 60, Margin, 60, 18);
  FSlider := TSlider.Create(Root);
  FSlider.SetBounds(Margin, Margin + 22, PopupWidth - 2 * Margin, 30);
  FSlider.SetRange(0, 100);
  FSlider.Position := State.Volume;
  FSlider.OnChange := @SliderChanged;
  FMute := TCheckBox.Create(Root);
  FMute.Text := '&Mute';
  FMute.Checked := State.Muted;
  FMute.SetBounds(Margin, PopupHeight - Margin - 23, 80, 23);
  FMute.OnChange := @MuteChanged;
  FSettingsButton := TButton.Create(Root);
  FSettingsButton.Text := '&Settings...';
  FSettingsButton.SetBounds(PopupWidth - Margin - 90, PopupHeight - Margin - 23, 90, 23);
  FSettingsButton.OnClick := @SettingsClicked;
  FValue.Text := IntToStr(FSlider.Position) + '%';
  FSlider.Enabled := HasOutput;
  FMute.Enabled := HasOutput;
  if not HasOutput then
    FValue.Text := 'no output';
  OnDismiss := @Closed;
end;

procedure TVolumePopup.Open;
var
  Value: LongInt;
begin
  Popup;
  Say('volume-popup');
  PrepareToReceive;
  Value := 0;
  while Value <= 100 do
  begin
    SayPlace('volume-' + IntToStr(Value), Self, FSlider.PixelBounds.Left + FSlider.PixelOfValue(Value),
      FSlider.PixelBounds.Top + Scaled(10));
    Value := Value + 10;
  end;
  SayPlace('volume-mute', Self, FMute.PixelBounds.Left + Scaled(6), FMute.PixelBounds.Top + Scaled(11));
  SayPlace('volume-settings', Self, (FSettingsButton.PixelBounds.Left + FSettingsButton.PixelBounds.Right) div 2,
    (FSettingsButton.PixelBounds.Top + FSettingsButton.PixelBounds.Bottom) div 2);
end;

procedure TVolumePopup.SliderChanged(Sender: TControl);
begin
  FValue.Text := IntToStr(FSlider.Position) + '%';
  SetAudioOutputVolume(FOutput, FSlider.Position);
  FChanged := True;
  Say('volume ' + IntToStr(FSlider.Position));
end;

procedure TVolumePopup.MuteChanged(Sender: TControl);
begin
  SetAudioOutputMuted(FOutput, FMute.Checked);
  FChanged := True;
  Say('mute ' + BoolToStr(FMute.Checked, 'on', 'off'));
end;

procedure TVolumePopup.SettingsClicked(Sender: TControl);
begin
  Dismiss;
  StartCommand('controlpanel', 'sound', 'Control Panel');
end;

{ The change is kept for the next boot by the service (anyone may). }
procedure TVolumePopup.KeepChange;
var
  Request: TSystemSettingsRequest;
begin
  Request := NewSystemSettingsRequest(SystemRequestSetVolume);
  Request.Output := LongWord(FOutput);
  Request.Volume := FSlider.Position;
  if FMute.Checked then
    Request.Flags := SystemFlagMuted;
  if AskSystemSettings(Request) = ErrorNone then
    Say('volume-kept ' + IntToStr(FSlider.Position));
end;

procedure TVolumePopup.Closed(Sender: TControl);
begin
  if FChanged then
    KeepChange;
  FChanged := False;
end;

end.

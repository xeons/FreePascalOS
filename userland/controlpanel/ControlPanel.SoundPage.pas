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
  The Sound page: each sound output's volume and mute, and which output
  is the default (where programs play that name none). The outputs are
  the kernel's (Audio.Outputs); choosing one in the list shows its
  volume. Applying sends what changed to the system settings service,
  which sets it and keeps it for the next boot; anyone may, as anyone
  at the machine could turn its knobs. Without the service the outputs
  are set directly, for this boot only.
}
unit ControlPanel.SoundPage;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Controls.Base,
  Controls.Window,
  Controls.Labels,
  Controls.ComboBox,
  Controls.Toggles,
  Controls.Slider,
  Audio.Outputs,
  ControlPanel.Pages;

type
  TOutputChoice = record
    Volume: LongWord;
    Muted: Boolean;
    LoadedVolume: LongWord;
    LoadedMuted: Boolean;
  end;

  TSoundPage = class(TSettingsPage)
  private
    FOutputs: TComboBox;
    FVolume: TSlider;
    FVolumeValue: TLabel;
    FMute: TCheckBox;
    FDefault: TComboBox;
    FChoices: array of TOutputChoice;
    FLoadedDefault: LongInt;
    FShowing: Boolean;
    procedure OutputChosen(Sender: TControl);
    procedure VolumeChanged(Sender: TControl);
    procedure MuteChanged(Sender: TControl);
    procedure ShowOutput;
    function ApplyOutput(Number: LongInt): Boolean;
  protected
    procedure LoadSettings; override;
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
  Sys.SystemSettings,
  Windowing.Connection,
  Controls.MessageBoxes,
  ControlPanel.Administrator,
  ControlPanel.Report;

const
  ControlLeft = PageMargin + LabelWidth;
  SliderWidth = 220;

constructor TSoundPage.CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string);
var
  Caption: TLabel;
begin
  inherited CreatePage(AParent, AWindow, ATitle);
  Caption := TLabel.Create(Self);
  Caption.Text := '&Output:';
  Caption.SetBounds(PageMargin, 32, LabelWidth - 6, 18);
  FOutputs := TComboBox.Create(Self);
  FOutputs.SetBounds(ControlLeft, 30, PageWidth - ControlLeft - PageMargin, 22);
  FOutputs.OnChange := @OutputChosen;
  Caption := TLabel.Create(Self);
  Caption.Text := '&Volume:';
  Caption.SetBounds(PageMargin, 74, LabelWidth - 6, 18);
  FVolume := TSlider.Create(Self);
  FVolume.SetBounds(ControlLeft, 72, SliderWidth, 30);
  FVolume.SetRange(0, 100);
  FVolume.TickStep := 10;
  FVolume.PageStep := 10;
  FVolume.OnChange := @VolumeChanged;
  FVolumeValue := TLabel.Create(Self);
  FVolumeValue.SetBounds(ControlLeft + SliderWidth + 10, 74, 50, 18);
  FMute := TCheckBox.Create(Self);
  FMute.Text := '&Mute';
  FMute.SetBounds(ControlLeft, 112, 120, 20);
  FMute.OnChange := @MuteChanged;
  Caption := TLabel.Create(Self);
  Caption.Text := '&Default output:';
  Caption.SetBounds(PageMargin, 158, LabelWidth - 6, 18);
  FDefault := TComboBox.Create(Self);
  FDefault.SetBounds(ControlLeft, 156, PageWidth - ControlLeft - PageMargin, 22);
  FDefault.OnChange := @ControlChanged;
end;

function TSoundPage.SettingsGroups: TStringArray;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := 'Sound';
end;

function TSoundPage.PageName: string;
begin
  Result := 'sound';
end;

procedure TSoundPage.ShowOutput;
var
  Number: LongInt;
begin
  Number := FOutputs.ItemIndex;
  if (Number < 0) or (Number > High(FChoices)) then
    Exit;
  FShowing := True;
  FVolume.Position := FChoices[Number].Volume;
  FMute.Checked := FChoices[Number].Muted;
  FShowing := False;
  FVolumeValue.Text := IntToStr(FVolume.Position) + '%';
end;

procedure TSoundPage.OutputChosen(Sender: TControl);
begin
  ShowOutput;
end;

procedure TSoundPage.VolumeChanged(Sender: TControl);
var
  Number: LongInt;
begin
  FVolumeValue.Text := IntToStr(FVolume.Position) + '%';
  Number := FOutputs.ItemIndex;
  if FShowing or (Number < 0) or (Number > High(FChoices)) then
    Exit;
  FChoices[Number].Volume := FVolume.Position;
  MarkModified;
end;

procedure TSoundPage.MuteChanged(Sender: TControl);
var
  Number: LongInt;
begin
  Number := FOutputs.ItemIndex;
  if FShowing or (Number < 0) or (Number > High(FChoices)) then
    Exit;
  FChoices[Number].Muted := FMute.Checked;
  MarkModified;
end;

procedure TSoundPage.LoadSettings;
var
  Number: LongInt;
  State: TAudioOutputState;
  Name: string;
begin
  FChoices := nil;
  FOutputs.Items.Clear;
  FDefault.Items.Clear;
  Number := 0;
  while DescribeAudioOutput(Number, State) do
  begin
    SetLength(FChoices, Number + 1);
    FChoices[Number].Volume := State.Volume;
    FChoices[Number].Muted := State.Muted;
    FChoices[Number].LoadedVolume := State.Volume;
    FChoices[Number].LoadedMuted := State.Muted;
    Name := Format('%s (%s)', [AudioOutputKindName(State.Kind), AudioOutputPath(Number)]);
    FOutputs.Items.Add(Name);
    FDefault.Items.Add(Name);
    Inc(Number);
  end;
  FLoadedDefault := DefaultAudioOutput;
  FDefault.ItemIndex := FLoadedDefault;
  if Length(FChoices) > 0 then
    FOutputs.ItemIndex := FLoadedDefault;
  ShowOutput;
  FVolume.Enabled := Length(FChoices) > 0;
  FMute.Enabled := Length(FChoices) > 0;
end;

function TSoundPage.ApplyOutput(Number: LongInt): Boolean;
var
  Request: TSystemSettingsRequest;
  Error: LongInt;
begin
  Request := NewSystemSettingsRequest(SystemRequestSetVolume);
  Request.Output := LongWord(Number);
  Request.Volume := FChoices[Number].Volume;
  if FChoices[Number].Muted then
    Request.Flags := SystemFlagMuted;
  Error := SendAsAnyone(Request);
  if Error <> ErrorNone then
  begin
    { No service: this boot only. }
    Error := SetAudioOutputVolume(Number, FChoices[Number].Volume);
    if Error = ErrorNone then
      Error := SetAudioOutputMuted(Number, FChoices[Number].Muted);
  end;
  Result := Error = ErrorNone;
  if not Result then
  begin
    ShowMessageBox('Sound', 'The volume could not be set. ' + RefusalText(Error), MessageOk, SignError, Window);
    Exit;
  end;
  FChoices[Number].LoadedVolume := FChoices[Number].Volume;
  FChoices[Number].LoadedMuted := FChoices[Number].Muted;
  Say(Format('applied volume %d %d%s', [Number, FChoices[Number].Volume, BoolToStr(FChoices[Number].Muted,
    ' muted', '')]));
end;

function TSoundPage.Apply: Boolean;
var
  Number: LongInt;
  Request: TSystemSettingsRequest;
  Error: LongInt;
begin
  Result := True;
  for Number := 0 to High(FChoices) do
    if (FChoices[Number].Volume <> FChoices[Number].LoadedVolume) or
       (FChoices[Number].Muted <> FChoices[Number].LoadedMuted) then
      if not ApplyOutput(Number) then
        Result := False;
  if (FDefault.ItemIndex >= 0) and (FDefault.ItemIndex <> FLoadedDefault) then
  begin
    Request := NewSystemSettingsRequest(SystemRequestSetDefaultOutput);
    Request.Output := LongWord(FDefault.ItemIndex);
    Error := SendAsAnyone(Request);
    if Error <> ErrorNone then
      Error := SetDefaultAudioOutput(FDefault.ItemIndex);
    if Error = ErrorNone then
    begin
      FLoadedDefault := FDefault.ItemIndex;
      Say(Format('applied default output %d', [FLoadedDefault]));
    end
    else
      Result := False;
  end;
  if Result then
    inherited Apply;
end;

procedure TSoundPage.TellPlaces;
begin
  SayPlace('sound-volume-0', Window, FVolume, FVolume.PixelOfValue(0), Scaled(10));
  SayPlace('sound-volume-40', Window, FVolume, FVolume.PixelOfValue(40), Scaled(10));
  SayPlace('sound-volume-100', Window, FVolume, FVolume.PixelOfValue(100), Scaled(10));
  SayControlPlace('sound-mute', Window, FMute);
  SayControlPlace('sound-output', Window, FOutputs);
end;

end.

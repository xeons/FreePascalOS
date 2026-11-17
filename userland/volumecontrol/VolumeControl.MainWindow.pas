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
  The volume control's window: the default output chosen in a list, a
  table with a row for every sound output (VolumeControl.OutputRow:
  name, volume slider, percent, Mute, peak meters), and buttons for the
  Control Panel's Sound page and closing. The rows are cells of a table
  panel whose slider column takes what the others leave; the list and
  the buttons sit in flow panels docked above and below. Compact (the
  pop-up kind, volumecontrol -c) shows only the default output, with a
  button to the whole mixer.

  Changes apply at once; each is kept for the next boot by the system
  settings service a moment later (when the slider stops, and when the
  window closes). What another program changes (the mixer command, the
  desktop's pop-up, the Control Panel) shows within a second, and at
  once when the system's sound settings change (Windowing.
  SettingsChanges).

    File     Exit
    View     Peak Meters (kept in the user's settings), Refresh (F5)
    Help     About Volume Control
}
unit VolumeControl.MainWindow;

{$mode objfpc}
{$H+}

interface

uses
  Configuration.Changes,
  Controls.Base,
  Controls.Window,
  Controls.Menus,
  Controls.Labels,
  Controls.Buttons,
  Controls.ComboBox,
  Controls.FlowPanel,
  Controls.TablePanel,
  Controls.Timers,
  VolumeControl.OutputRow;

type
  TVolumeControlWindow = class(TControlWindow)
  private
    FCompact: Boolean;
    FMenuBar: TMenuBar;
    FMetersItem: TMenuItem;
    FDefaultRow: TFlowLayoutPanel;
    FDefaultBox: TComboBox;
    FTable: TTableLayoutPanel;
    FButtonRow: TFlowLayoutPanel;
    FNoOutputs: TLabel;
    FRows: array of TOutputRow;
    FTimer: TTimer;
    FTicks: LongInt;
    FDefaultOutput: LongInt;
    FChoosingDefault: Boolean;
    procedure BuildMenus;
    procedure BuildDefaultRow;
    procedure BuildTable;
    procedure BuildButtons;
    procedure AddHeader(const Caption: string; Column: LongInt);
    procedure ListOutputs;
    procedure RefreshAll;
    procedure KeepChanges(Closing: Boolean);
    procedure SetMetersShown(Shown: Boolean);
    procedure TimerTicked(Sender: TTimer);
    procedure DefaultChosen(Sender: TControl);
    procedure SettingsClicked(Sender: TControl);
    procedure MixerClicked(Sender: TControl);
    procedure CloseClicked(Sender: TControl);
    procedure ExitChosen(Item: TMenuItem);
    procedure MetersChosen(Item: TMenuItem);
    procedure RefreshChosen(Item: TMenuItem);
    procedure AboutChosen(Item: TMenuItem);
    procedure SoundSettingsChanged(const Group: string; const Changes: TSettingChanges);
    procedure OwnSettingsChanged(const Group: string; const Changes: TSettingChanges);
  protected
    procedure CloseRequested; override;
  public
    constructor Create(Compact: Boolean);
    destructor Destroy; override;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Windowing.Windows,
  Windowing.SettingsChanges,
  Audio.Outputs,
  Controls.Text,
  Controls.Keys,
  Controls.LayoutRules,
  Controls.TableArrangement,
  Controls.FlowArrangement,
  Controls.MessageBoxes,
  VolumeControl.Settings,
  VolumeControl.Launching,
  VolumeControl.Output;

const
  ProgramName = 'Volume Control';
  { Milliseconds between meter readings; the outputs are looked at every
    RefreshTicks of them. }
  MeterInterval = 100;
  RefreshTicks = 10;
  { Logical units. }
  WindowWidth = 520;
  WindowHeight = 260;
  CompactWidth = 340;
  CompactHeight = 120;
  Padding = 8;
  ValueColumnWidth = 44;
  MeterColumnWidth = 90;
  RowHeight = 34;
  NoKey = 0;
  KeyF5 = $3F;

constructor TVolumeControlWindow.Create(Compact: Boolean);
var
  Width: LongInt;
  Height: LongInt;
begin
  FCompact := Compact;
  Width := WindowWidth;
  Height := WindowHeight;
  if Compact then
  begin
    Width := CompactWidth;
    Height := CompactHeight;
  end;
  inherited Create(ProgramName, 160, 120, Width, Height);
  Root.ContentPadding := MakeSpacing(0, 0, 0, 0);
  if not Compact then
    BuildMenus;
  BuildDefaultRow;
  BuildButtons;
  BuildTable;
  ListOutputs;
  SetMetersShown(RememberedPeakMeters);
  FTimer := TTimer.Create(Self);
  FTimer.Interval := MeterInterval;
  FTimer.OnTimer := @TimerTicked;
  FTimer.Start;
  SubscribeToSettings(SoundSettingsGroup, @SoundSettingsChanged);
  SubscribeToSettings(VolumeControlSettingsGroup, @OwnSettingsChanged);
end;

destructor TVolumeControlWindow.Destroy;
var
  Index: LongInt;
begin
  UnsubscribeFromSettings(@SoundSettingsChanged);
  UnsubscribeFromSettings(@OwnSettingsChanged);
  FTimer.Free;
  for Index := 0 to High(FRows) do
    FRows[Index].Free;
  inherited Destroy;
end;

{ --- Building ------------------------------------------------------------------------ }

procedure TVolumeControlWindow.BuildMenus;
var
  Menu: TMenuItem;
  Item: TMenuItem;
begin
  FMenuBar := TMenuBar.Create(Root);
  Menu := FMenuBar.Menu.Add('&File');
  Menu.Add('E&xit', @ExitChosen);
  Menu := FMenuBar.Menu.Add('&View');
  FMetersItem := Menu.Add('&Peak Meters', @MetersChosen);
  Item := Menu.Add('&Refresh', @RefreshChosen, 'F5');
  AddItemAccelerator(Self, Item, KeyF5, 0);
  Menu := FMenuBar.Menu.Add('&Help');
  Menu.Add('&About Volume Control', @AboutChosen);
end;

procedure TVolumeControlWindow.BuildDefaultRow;
var
  Caption: TLabel;
begin
  FDefaultRow := TFlowLayoutPanel.Create(Root);
  FDefaultRow.Align := AlignTop;
  FDefaultRow.AutoSize := True;
  FDefaultRow.ContentPadding := MakeSpacing(Padding, Padding, Padding, 0);
  FDefaultRow.Visible := not FCompact;
  Caption := TLabel.Create(FDefaultRow);
  Caption.Text := '&Default output:';
  Caption.AutoSize := True;
  Caption.Margins := MakeSpacing(0, 4, 8, 0);
  FDefaultBox := TComboBox.Create(FDefaultRow);
  FDefaultBox.SetBounds(0, 0, 220, 24);
  FDefaultBox.OnChange := @DefaultChosen;
end;

procedure TVolumeControlWindow.AddHeader(const Caption: string; Column: LongInt);
var
  Header: TLabel;
begin
  Header := TLabel.Create(FTable);
  Header.Text := Caption;
  Header.ShowsMnemonic := False;
  Header.AutoSize := True;
  Header.Anchors := [akLeft, akBottom];
  FTable.SetCell(Header, Column, 0);
end;

procedure TVolumeControlWindow.BuildTable;
begin
  FTable := TTableLayoutPanel.Create(Root);
  FTable.Align := AlignClient;
  FTable.ContentPadding := MakeSpacing(Padding, Padding, Padding, Padding);
  FTable.AddColumn(TrackAutoSize);
  FTable.AddColumn(TrackPercent, 1);
  FTable.AddColumn(TrackAbsolute, ValueColumnWidth);
  FTable.AddColumn(TrackAutoSize);
  FTable.AddColumn(TrackAbsolute, MeterColumnWidth);
  FTable.AddRow(TrackAutoSize);
  FTable.GrowStyle := GrowAddRows;
  if not FCompact then
  begin
    AddHeader('Output', 0);
    AddHeader('Volume', 1);
    AddHeader('Level', 4);
  end;
  FNoOutputs := TLabel.Create(Root);
  FNoOutputs.Text := 'There is no sound output.';
  FNoOutputs.ShowsMnemonic := False;
  FNoOutputs.Align := AlignClient;
  FNoOutputs.Alignment := AlignTextCenter;
  FNoOutputs.Visible := False;
end;

procedure TVolumeControlWindow.BuildButtons;
var
  Button: TButton;
begin
  FButtonRow := TFlowLayoutPanel.Create(Root);
  FButtonRow.Align := AlignBottom;
  FButtonRow.AutoSize := True;
  FButtonRow.FlowDirection := FlowRightToLeft;
  FButtonRow.ContentPadding := MakeSpacing(Padding, 0, Padding, Padding);
  Button := TButton.Create(FButtonRow);
  Button.Text := 'Close';
  Button.SetBounds(0, 0, 80, 24);
  Button.Margins := MakeSpacing(6, 0, 0, 0);
  Button.OnClick := @CloseClicked;
  CancelControl := Button;
  Button := TButton.Create(FButtonRow);
  Button.SetBounds(0, 0, 120, 24);
  if FCompact then
  begin
    Button.Text := '&Mixer...';
    Button.OnClick := @MixerClicked;
  end
  else
  begin
    Button.Text := '&Sound Settings...';
    Button.OnClick := @SettingsClicked;
  end;
end;

{ A row for every output there is (only the default one when compact),
  the default output chosen in the list. }
procedure TVolumeControlWindow.ListOutputs;
var
  Count: LongInt;
  Number: LongInt;
  State: TAudioOutputState;
  Row: TOutputRow;
  TableRow: LongInt;
begin
  Count := AudioOutputCount;
  FDefaultOutput := DefaultAudioOutput;
  Say('outputs ' + IntToStr(Count));
  FChoosingDefault := True;
  try
    for Number := 0 to Count - 1 do
    begin
      if not DescribeAudioOutput(Number, State) then
        Continue;
      FDefaultBox.Items.Add(IntToStr(Number + 1) + ' ' + AudioOutputKindName(State.Kind));
      Say(Format('output %d %s volume %d muted %s default %s', [Number, AudioOutputKindName(State.Kind),
        State.Volume, BoolToStr(State.Muted, 'on', 'off'), BoolToStr(Number = FDefaultOutput, 'yes', 'no')]));
      if FCompact and (Number <> FDefaultOutput) then
        Continue;
      TableRow := Length(FRows) + 1;
      FTable.AddRow(TrackAbsolute, RowHeight);
      Row := TOutputRow.Create(FTable, TableRow, Number);
      Row.IsDefault := Number = FDefaultOutput;
      Row.Refresh;
      SetLength(FRows, Length(FRows) + 1);
      FRows[High(FRows)] := Row;
    end;
    if (FDefaultOutput >= 0) and (FDefaultOutput < FDefaultBox.Items.Count) then
      FDefaultBox.ItemIndex := FDefaultOutput;
  finally
    FChoosingDefault := False;
  end;
  FTable.Visible := Length(FRows) > 0;
  FNoOutputs.Visible := Length(FRows) = 0;
  FDefaultBox.Enabled := Count > 1;
  if Length(FRows) > 0 then
    FocusControl(FRows[0].Slider);
end;

{ --- Keeping up ---------------------------------------------------------------------------- }

procedure TVolumeControlWindow.RefreshAll;
var
  Index: LongInt;
  Default: LongInt;
begin
  Default := DefaultAudioOutput;
  if Default <> FDefaultOutput then
  begin
    FDefaultOutput := Default;
    FChoosingDefault := True;
    try
      if Default < FDefaultBox.Items.Count then
        FDefaultBox.ItemIndex := Default;
    finally
      FChoosingDefault := False;
    end;
  end;
  for Index := 0 to High(FRows) do
  begin
    FRows[Index].IsDefault := FRows[Index].Number = FDefaultOutput;
    FRows[Index].Refresh;
  end;
end;

{ Changes made since the last time, kept for the next boot (not while
  the slider is still being dragged, unless the window is closing). }
procedure TVolumeControlWindow.KeepChanges(Closing: Boolean);
var
  Index: LongInt;
  Row: TOutputRow;
begin
  for Index := 0 to High(FRows) do
  begin
    Row := FRows[Index];
    if not Row.Changed or (Row.Slider.Tracking and not Closing) then
      Continue;
    Row.Changed := False;
    if KeepVolume(Row.Number, Row.Slider.Position, Row.Mute.Checked) then
      Say('kept ' + IntToStr(Row.Number) + ' ' + IntToStr(Row.Slider.Position));
  end;
end;

procedure TVolumeControlWindow.TimerTicked(Sender: TTimer);
var
  Index: LongInt;
begin
  for Index := 0 to High(FRows) do
    FRows[Index].UpdateMeters(MeterInterval);
  Inc(FTicks);
  if FTicks mod RefreshTicks <> 0 then
    Exit;
  KeepChanges(False);
  RefreshAll;
end;

procedure TVolumeControlWindow.SetMetersShown(Shown: Boolean);
var
  Index: LongInt;
begin
  if FMetersItem <> nil then
    FMetersItem.Checked := Shown;
  for Index := 0 to High(FRows) do
    FRows[Index].SetMetersShown(Shown);
end;

procedure TVolumeControlWindow.SoundSettingsChanged(const Group: string; const Changes: TSettingChanges);
begin
  RefreshAll;
end;

procedure TVolumeControlWindow.OwnSettingsChanged(const Group: string; const Changes: TSettingChanges);
begin
  SetMetersShown(RememberedPeakMeters);
end;

{ --- Commands -------------------------------------------------------------------------------- }

procedure TVolumeControlWindow.DefaultChosen(Sender: TControl);
var
  Chosen: LongInt;
begin
  if FChoosingDefault then
    Exit;
  Chosen := FDefaultBox.ItemIndex;
  if (Chosen < 0) or (Chosen = FDefaultOutput) then
    Exit;
  if SetDefaultAudioOutput(Chosen) <> ErrorNone then
    Exit;
  KeepDefaultOutput(Chosen);
  Say('default ' + IntToStr(Chosen));
  RefreshAll;
end;

procedure TVolumeControlWindow.SettingsClicked(Sender: TControl);
begin
  StartProgramCommand('controlpanel', 'sound', Self);
end;

procedure TVolumeControlWindow.MixerClicked(Sender: TControl);
begin
  if StartProgramCommand('volumecontrol', '', Self) then
    CloseRequested;
end;

procedure TVolumeControlWindow.CloseClicked(Sender: TControl);
begin
  CloseRequested;
end;

procedure TVolumeControlWindow.ExitChosen(Item: TMenuItem);
begin
  CloseRequested;
end;

procedure TVolumeControlWindow.MetersChosen(Item: TMenuItem);
begin
  Item.Checked := not Item.Checked;
  SetMetersShown(Item.Checked);
  RememberPeakMeters(Item.Checked);
end;

procedure TVolumeControlWindow.RefreshChosen(Item: TMenuItem);
begin
  RefreshAll;
end;

procedure TVolumeControlWindow.AboutChosen(Item: TMenuItem);
begin
  ShowMessageBox('About Volume Control', 'Volume Control'#10'The sound outputs'' volumes, mutes and levels on ' +
    'FreePascalOS.', MessageOk, SignInformation, Self);
end;

procedure TVolumeControlWindow.CloseRequested;
begin
  KeepChanges(True);
  Say('exit');
  QuitMessageLoop(0);
end;

end.

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
  One sound output in the volume control's table: its name, a volume
  slider, the volume in percent, Mute, and a peak meter for each side
  (two thin bars, from the output's monitor: VolumeControl.PeakMonitor).
  Each control goes in a cell of the row given (the table sizes the
  columns: the slider takes what is left), so the row has no positions
  of its own.

  The slider and Mute act on the output at once (Audio.Outputs); the row
  remembers that it changed (Changed) for the window to keep the change
  for the next boot. Refresh shows what the output has now, unless the
  slider is being dragged.
}
unit VolumeControl.OutputRow;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Labels,
  Controls.Slider,
  Controls.Toggles,
  Controls.ProgressBar,
  Controls.TablePanel,
  VolumeControl.Levels,
  VolumeControl.PeakMonitor;

type
  TOutputRow = class
  private
    FNumber: LongInt;
    FNameLabel: TLabel;
    FSlider: TSlider;
    FValueLabel: TLabel;
    FMute: TCheckBox;
    FMeters: TTableLayoutPanel;
    FLeftMeter: TProgressBar;
    FRightMeter: TProgressBar;
    FMonitor: TPeakMonitor;
    FChanged: Boolean;
    FShowing: Boolean;
    FLeftLevel: LongInt;
    FRightLevel: LongInt;
    FIsDefault: Boolean;
    FKindName: string;
    procedure SliderChanged(Sender: TControl);
    procedure MuteChanged(Sender: TControl);
    function NewMeter: TProgressBar;
    procedure ShowValue;
  public
    { The row of output Number in Table's row Row. }
    constructor Create(Table: TTableLayoutPanel; Row, Number: LongInt);
    destructor Destroy; override;
    { Shows the output's volume, mute and name now. }
    procedure Refresh;
    { Reads the monitor and moves the meters (Milliseconds since the
      last time). }
    procedure UpdateMeters(Milliseconds: LongInt);
    procedure SetMetersShown(Shown: Boolean);
    property Number: LongInt read FNumber;
    property Slider: TSlider read FSlider;
    property Mute: TCheckBox read FMute;
    { Changed by the user since the last time this was cleared. }
    property Changed: Boolean read FChanged write FChanged;
    property IsDefault: Boolean read FIsDefault write FIsDefault;
    property KindName: string read FKindName;
  end;

implementation

uses
  SysUtils,
  Audio.Outputs,
  Controls.Text,
  Controls.LayoutRules,
  Controls.TableArrangement,
  VolumeControl.Output;

const
  ColumnName = 0;
  ColumnSlider = 1;
  ColumnValue = 2;
  ColumnMute = 3;
  ColumnMeter = 4;
  { Logical units. }
  CellGap = 4;
  MeterGap = 1;

constructor TOutputRow.Create(Table: TTableLayoutPanel; Row, Number: LongInt);
begin
  inherited Create;
  FNumber := Number;
  FNameLabel := TLabel.Create(Table);
  FNameLabel.AutoSize := True;
  FNameLabel.Anchors := [akLeft];
  FNameLabel.Margins := MakeSpacing(0, 0, CellGap, 0);
  FSlider := TSlider.Create(Table);
  FSlider.SetRange(0, 100);
  FSlider.PageStep := 10;
  FSlider.AutoSize := True;
  FSlider.Anchors := [akLeft, akRight];
  FSlider.OnChange := @SliderChanged;
  FValueLabel := TLabel.Create(Table);
  FValueLabel.ShowsMnemonic := False;
  FValueLabel.Alignment := AlignTextRight;
  FValueLabel.Align := AlignClient;
  FMute := TCheckBox.Create(Table);
  FMute.Text := 'Mute';
  FMute.AutoSize := True;
  FMute.Anchors := [akLeft];
  FMute.Margins := MakeSpacing(CellGap, 0, CellGap, 0);
  FMute.OnChange := @MuteChanged;
  FMeters := TTableLayoutPanel.Create(Table);
  FMeters.Align := AlignClient;
  FMeters.Margins := MakeSpacing(0, CellGap * 2, 0, CellGap * 2);
  FMeters.AddColumn(TrackPercent, 1);
  FMeters.AddRow(TrackPercent, 1);
  FMeters.AddRow(TrackPercent, 1);
  FMeters.GrowStyle := GrowFixedSize;
  FLeftMeter := NewMeter;
  FRightMeter := NewMeter;
  FMeters.SetCell(FLeftMeter, 0, 0);
  FMeters.SetCell(FRightMeter, 0, 1);
  Table.SetCell(FNameLabel, ColumnName, Row);
  Table.SetCell(FSlider, ColumnSlider, Row);
  Table.SetCell(FValueLabel, ColumnValue, Row);
  Table.SetCell(FMute, ColumnMute, Row);
  Table.SetCell(FMeters, ColumnMeter, Row);
  FMonitor := TPeakMonitor.Create(Number);
  FMeters.Visible := FMonitor.Available;
  Refresh;
end;

destructor TOutputRow.Destroy;
begin
  FMonitor.Free;
  inherited Destroy;
end;

function TOutputRow.NewMeter: TProgressBar;
begin
  Result := TProgressBar.Create(FMeters);
  Result.Maximum := 100;
  Result.Align := AlignClient;
  Result.Margins := MakeSpacing(0, MeterGap, 0, MeterGap);
end;

procedure TOutputRow.ShowValue;
begin
  FValueLabel.Text := IntToStr(FSlider.Position) + '%';
end;

procedure TOutputRow.Refresh;
var
  State: TAudioOutputState;
  Caption: string;
begin
  if not DescribeAudioOutput(FNumber, State) then
    Exit;
  FKindName := AudioOutputKindName(State.Kind);
  Caption := '&' + IntToStr(FNumber + 1) + ' ' + FKindName;
  if FIsDefault then
    Caption := Caption + ' (default)';
  FNameLabel.Text := Caption;
  FShowing := True;
  try
    if not FSlider.Tracking and (LongInt(State.Volume) <> FSlider.Position) then
      FSlider.Position := State.Volume;
    if FMute.Checked <> State.Muted then
      FMute.Checked := State.Muted;
  finally
    FShowing := False;
  end;
  ShowValue;
end;

procedure TOutputRow.SliderChanged(Sender: TControl);
begin
  ShowValue;
  if FShowing then
    Exit;
  SetAudioOutputVolume(FNumber, FSlider.Position);
  FChanged := True;
  Say('volume ' + IntToStr(FNumber) + ' ' + IntToStr(FSlider.Position));
end;

procedure TOutputRow.MuteChanged(Sender: TControl);
begin
  if FShowing then
    Exit;
  SetAudioOutputMuted(FNumber, FMute.Checked);
  FChanged := True;
  Say('mute ' + IntToStr(FNumber) + ' ' + BoolToStr(FMute.Checked, 'on', 'off'));
end;

procedure TOutputRow.UpdateMeters(Milliseconds: LongInt);
var
  Peak: TStereoPeak;
begin
  if not FMeters.Visible then
    Exit;
  if not FMonitor.ReadPeak(Peak) then
  begin
    Peak.Left := 0;
    Peak.Right := 0;
  end;
  FLeftLevel := FallenMeter(FLeftLevel, MeterPercent(Peak.Left), Milliseconds);
  FRightLevel := FallenMeter(FRightLevel, MeterPercent(Peak.Right), Milliseconds);
  if FLeftMeter.Position <> FLeftLevel then
    FLeftMeter.Position := FLeftLevel;
  if FRightMeter.Position <> FRightLevel then
    FRightMeter.Position := FRightLevel;
end;

procedure TOutputRow.SetMetersShown(Shown: Boolean);
begin
  FMeters.Visible := Shown and FMonitor.Available;
end;

end.

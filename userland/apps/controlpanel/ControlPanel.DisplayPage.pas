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
  The Display page: for each display, its resolution (one of its modes)
  and its scale (100% to 300%), through the display server
  (Windowing.Displays).

  Applying sets them for now and asks whether to keep them, with a
  countdown (ControlPanel.KeepSettingsDialog): kept, they are asked
  again with the server's DisplayRemember, which keeps them in the
  system's settings for the next start (a display's mode and scale are
  the machine's); otherwise they go back as they were.
}
unit ControlPanel.DisplayPage;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Controls.Base,
  Controls.Window,
  Controls.Labels,
  Controls.ComboBox,
  ControlPanel.Pages;

type
  TDisplayMode = record
    Width: LongInt;
    Height: LongInt;
  end;

  TDisplayPage = class(TSettingsPage)
  private
    FDisplays: TComboBox;
    FModes: TComboBox;
    FScales: TComboBox;
    FDetails: TLabel;
    FModeList: array of TDisplayMode;
    FLoadedMode: LongInt;
    FLoadedScale: LongInt;
    procedure DisplayChosen(Sender: TControl);
    procedure LoadDisplay;
    function DisplayNumber: LongInt;
    procedure SetDisplay(ModeIndex, ScaleIndex: LongInt; Remember: Boolean);
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
  Windowing.Connection,
  Windowing.Displays,
  ControlPanel.KeepSettingsDialog,
  ControlPanel.Report;

const
  ControlLeft = PageMargin + LabelWidth;
  ScaleCount = 9;
  ScalePercents: array[0..ScaleCount - 1] of LongInt = (100, 125, 150, 175, 200, 225, 250, 275, 300);

constructor TDisplayPage.CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string);
var
  Caption: TLabel;
  Index: LongInt;
begin
  inherited CreatePage(AParent, AWindow, ATitle);
  Caption := TLabel.Create(Self);
  Caption.Text := '&Display:';
  Caption.SetBounds(PageMargin, 32, LabelWidth - 6, 18);
  FDisplays := TComboBox.Create(Self);
  FDisplays.SetBounds(ControlLeft, 30, PageWidth - ControlLeft - PageMargin, 22);
  FDisplays.OnChange := @DisplayChosen;
  Caption := TLabel.Create(Self);
  Caption.Text := '&Resolution:';
  Caption.SetBounds(PageMargin, 72, LabelWidth - 6, 18);
  FModes := TComboBox.Create(Self);
  FModes.SetBounds(ControlLeft, 70, 160, 22);
  FModes.OnChange := @ControlChanged;
  Caption := TLabel.Create(Self);
  Caption.Text := '&Scale:';
  Caption.SetBounds(PageMargin, 112, LabelWidth - 6, 18);
  FScales := TComboBox.Create(Self);
  FScales.SetBounds(ControlLeft, 110, 160, 22);
  for Index := 0 to ScaleCount - 1 do
    FScales.Items.Add(IntToStr(ScalePercents[Index]) + '%');
  FScales.OnChange := @ControlChanged;
  FDetails := TLabel.Create(Self);
  FDetails.ShowsMnemonic := False;
  FDetails.SetBounds(ControlLeft, 146, PageWidth - ControlLeft - PageMargin, 18);
end;

function TDisplayPage.SettingsGroups: TStringArray;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := 'Display';
end;

function TDisplayPage.PageName: string;
begin
  Result := 'display';
end;

function TDisplayPage.DisplayNumber: LongInt;
begin
  Result := FDisplays.ItemIndex;
  if Result < 0 then
    Result := 0;
end;

function ScaleIndexOf(Percent: LongInt): LongInt;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to ScaleCount - 1 do
    if ScalePercents[Index] <= Percent then
      Result := Index;
end;

procedure TDisplayPage.LoadDisplay;
var
  Information: TDisplayInformation;
  Index: LongInt;
  Width: LongInt;
  Height: LongInt;
  Current: Boolean;
begin
  FModeList := nil;
  FModes.Items.Clear;
  FLoadedMode := -1;
  Index := 0;
  while DescribeDisplayMode(DisplayNumber, Index, Width, Height, Current) do
  begin
    SetLength(FModeList, Index + 1);
    FModeList[Index].Width := Width;
    FModeList[Index].Height := Height;
    FModes.Items.Add(Format('%d x %d', [Width, Height]));
    if Current then
      FLoadedMode := Index;
    Inc(Index);
  end;
  FModes.ItemIndex := FLoadedMode;
  if DescribeDisplay(DisplayNumber, Information) then
  begin
    FLoadedScale := ScaleIndexOf(Information.ScalePercent);
    FDetails.Text := Format('%d x %d pixels, %d DPI at %d%%', [Information.Width, Information.Height,
      Information.Dpi, Information.ScalePercent]);
  end
  else
    FLoadedScale := 0;
  FScales.ItemIndex := FLoadedScale;
end;

procedure TDisplayPage.DisplayChosen(Sender: TControl);
begin
  LoadDisplay;
end;

procedure TDisplayPage.LoadSettings;
var
  Count: LongInt;
  Number: LongInt;
  Information: TDisplayInformation;
  Chosen: LongInt;
begin
  Chosen := DisplayNumber;
  FDisplays.Items.Clear;
  Count := CountDisplays;
  for Number := 0 to Count - 1 do
    if DescribeDisplay(Number, Information) then
      FDisplays.Items.Add(Format('Display %d (%d x %d)', [Number + 1, Information.Width, Information.Height]));
  if Chosen >= FDisplays.Items.Count then
    Chosen := 0;
  FDisplays.ItemIndex := Chosen;
  LoadDisplay;
end;

procedure TDisplayPage.SetDisplay(ModeIndex, ScaleIndex: LongInt; Remember: Boolean);
var
  Information: TDisplayInformation;
begin
  if (ModeIndex >= 0) and (ModeIndex <= High(FModeList)) then
    SetDisplayMode(DisplayNumber, FModeList[ModeIndex].Width, FModeList[ModeIndex].Height, Information, Remember);
  SetDisplayScale(DisplayNumber, ScalePercents[ScaleIndex], Information, Remember);
end;

function TDisplayPage.Apply: Boolean;
var
  NewMode: LongInt;
  NewScale: LongInt;
  ModeChanged: Boolean;
  Information: TDisplayInformation;
begin
  Result := True;
  NewMode := FModes.ItemIndex;
  NewScale := FScales.ItemIndex;
  if NewScale < 0 then
    NewScale := FLoadedScale;
  ModeChanged := (NewMode >= 0) and (NewMode <> FLoadedMode);
  if not ModeChanged and (NewScale = FLoadedScale) then
  begin
    inherited Apply;
    Exit;
  end;
  if ModeChanged then
    SetDisplay(NewMode, NewScale, False)
  else
    SetDisplayScale(DisplayNumber, ScalePercents[NewScale], Information, False);
  Say(Format('applied display %d mode %s scale %d', [DisplayNumber, FModes.Text, ScalePercents[NewScale]]));
  if AskToKeepSettings(Window) then
  begin
    { Asked again, kept by the server this time. }
    if ModeChanged then
      SetDisplay(NewMode, NewScale, True)
    else
      SetDisplayScale(DisplayNumber, ScalePercents[NewScale], Information, True);
    Say('kept');
  end
  else
  begin
    SetDisplay(FLoadedMode, FLoadedScale, False);
    Say('reverted');
  end;
  Load;
end;

procedure TDisplayPage.TellPlaces;
begin
  SayControlPlace('display-modes', Window, FModes);
  SayControlPlace('display-scales', Window, FScales);
end;

end.

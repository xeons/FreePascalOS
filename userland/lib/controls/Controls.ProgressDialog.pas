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
  Progress dialogs: how a long operation (a copy, a move, a delete) is
  getting on, for any program.

  A heading says what is being done ("Copying 12 items from A to B",
  SetHeading), a line how much ("34% complete"), with a bar and Pause
  (Resume while paused; OnPauseChanged) and Cancel (OnCancel, as is its
  close button) beside it. "More details" opens the rest: a graph of
  the speed over the operation (Controls.ThroughputGraph) and lines
  for the speed, the item it is on, the time left and the items left,
  which come from the samples UpdateProgress gives a transfer rate
  meter (Controls.TransferRates); paused time does not count.

  It is not modal: the program shows it (Show, perhaps only once the
  operation has run for a while), calls UpdateProgress as work gets
  done, and hides or frees it at the end. It is centred on its owner.
}
unit Controls.ProgressDialog;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Windowing.Windows,
  Controls.Base,
  Controls.Labels,
  Controls.Buttons,
  Controls.ProgressBar,
  Controls.Dialogs,
  Controls.DisclosureButton,
  Controls.ThroughputGraph,
  Controls.TransferRates;

type
  TProgressDialog = class;

  TProgressDialogEvent = procedure(Sender: TProgressDialog) of object;
  TPauseChangedEvent = procedure(Sender: TProgressDialog; Paused: Boolean) of object;

  TProgressDialog = class(TDialog)
  private
    FMeter: TTransferRateMeter;
    FHeadingLabel: TLabel;
    FPercentLabel: TLabel;
    FBar: TProgressBar;
    FPauseButton: TButton;
    FCancelButton: TButton;
    FDetailsToggle: TDisclosureButton;
    FGraph: TThroughputGraph;
    FSpeedLabel: TLabel;
    FNameLabel: TLabel;
    FTimeLabel: TLabel;
    FItemsLabel: TLabel;
    FPaused: Boolean;
    FCancelled: Boolean;
    FPercent: LongInt;
    FOnPauseChanged: TPauseChangedEvent;
    FOnCancel: TProgressDialogEvent;
    function NewLabel(Top: LongInt): TLabel;
    procedure PauseClicked(Sender: TControl);
    procedure CancelClicked(Sender: TControl);
    procedure DetailsToggled(Sender: TControl);
    procedure SetPaused(Value: Boolean);
    procedure SetDetailsShown(Value: Boolean);
    function GetDetailsShown: Boolean;
    procedure ShowPercent;
    procedure PlaceDetails;
  protected
    procedure CloseRequested; override;
  public
    { Titled ATitle ("Copying"), centred on AOwner (nil: the screen);
      hidden until Show. }
    constructor CreateProgress(AOwner: TWindow; const ATitle: string);
    destructor Destroy; override;
    procedure SetHeading(const Text: string);
    { Where the operation is, measured now. }
    procedure UpdateProgress(BytesDone, BytesTotal: QWord; ItemsDone, ItemsTotal: LongInt; const CurrentName: string);
    { The same measured at TimeMilliseconds (any clock that only goes
      forward). }
    procedure UpdateProgressAt(TimeMilliseconds: QWord; BytesDone, BytesTotal: QWord; ItemsDone, ItemsTotal: LongInt;
      const CurrentName: string);
    { As Cancel does: OnCancel, the buttons disabled. }
    procedure Cancel;
    { Where the buttons are (the window's pixels). }
    function PauseButtonBounds: TRectangle;
    function CancelButtonBounds: TRectangle;
    function DetailsToggleBounds: TRectangle;
    property Meter: TTransferRateMeter read FMeter;
    { Setting it is announced (OnPauseChanged), as a click is. }
    property Paused: Boolean read FPaused write SetPaused;
    property Cancelled: Boolean read FCancelled;
    property DetailsShown: Boolean read GetDetailsShown write SetDetailsShown;
    property OnPauseChanged: TPauseChangedEvent read FOnPauseChanged write FOnPauseChanged;
    property OnCancel: TProgressDialogEvent read FOnCancel write FOnCancel;
  end;

implementation

uses
  SysUtils,
  Sys.Time;

const
  { Logical units. }
  DialogWidth = 460;
  Margin = 12;
  ButtonWidth = 76;
  ButtonHeight = 24;
  ButtonGap = 6;
  LabelHeight = 18;
  HeadingTop = 12;
  PercentTop = 38;
  BarTop = 66;
  BarHeight = 20;
  ToggleTopCollapsed = 100;
  GraphTop = 100;
  GraphHeight = 90;
  DetailLinesTop = 198;
  DetailLineStep = 20;
  ToggleTopExpanded = 284;
  ToggleWidth = 130;
  BottomRoom = 12;
  BarSteps = 1000;

constructor TProgressDialog.CreateProgress(AOwner: TWindow; const ATitle: string);
var
  Right: LongInt;
begin
  inherited CreateDialog(ATitle, DialogWidth, ToggleTopCollapsed + ButtonHeight + BottomRoom, AOwner);
  FMeter := TTransferRateMeter.Create;
  FHeadingLabel := NewLabel(HeadingTop);
  FPercentLabel := NewLabel(PercentTop);
  Right := DialogWidth - Margin;
  FCancelButton := TButton.Create(Root);
  FCancelButton.Text := 'Cancel';
  FCancelButton.SetBounds(Right - ButtonWidth, BarTop + (BarHeight - ButtonHeight) div 2, ButtonWidth, ButtonHeight);
  FCancelButton.OnClick := @CancelClicked;
  FPauseButton := TButton.Create(Root);
  FPauseButton.Text := 'Pause';
  FPauseButton.SetBounds(Right - 2 * ButtonWidth - ButtonGap, BarTop + (BarHeight - ButtonHeight) div 2, ButtonWidth,
    ButtonHeight);
  FPauseButton.OnClick := @PauseClicked;
  FBar := TProgressBar.Create(Root);
  FBar.Maximum := BarSteps;
  FBar.SetBounds(Margin, BarTop, Right - 2 * ButtonWidth - 2 * ButtonGap - Margin, BarHeight);
  FDetailsToggle := TDisclosureButton.Create(Root);
  FDetailsToggle.OnChange := @DetailsToggled;
  FGraph := TThroughputGraph.Create(Root);
  FGraph.Meter := FMeter;
  FGraph.SetBounds(Margin, GraphTop, DialogWidth - 2 * Margin, GraphHeight);
  FSpeedLabel := NewLabel(DetailLinesTop);
  FNameLabel := NewLabel(DetailLinesTop + DetailLineStep);
  FTimeLabel := NewLabel(DetailLinesTop + 2 * DetailLineStep);
  FItemsLabel := NewLabel(DetailLinesTop + 3 * DetailLineStep);
  CancelControl := FCancelButton;
  FocusControl(FCancelButton);
  PlaceDetails;
  ShowPercent;
end;

destructor TProgressDialog.Destroy;
begin
  inherited Destroy;
  FMeter.Free;
end;

function TProgressDialog.NewLabel(Top: LongInt): TLabel;
begin
  Result := TLabel.Create(Root);
  Result.ShowsMnemonic := False;
  Result.SetBounds(Margin, Top, DialogWidth - 2 * Margin, LabelHeight);
end;

procedure TProgressDialog.SetHeading(const Text: string);
begin
  FHeadingLabel.Text := Text;
end;

{ The details shown or not, the toggle under what is shown and the
  window as tall as it all. }
procedure TProgressDialog.PlaceDetails;
var
  Shown: Boolean;
  ToggleTop: LongInt;
begin
  Shown := FDetailsToggle.Expanded;
  FGraph.Visible := Shown;
  FSpeedLabel.Visible := Shown;
  FNameLabel.Visible := Shown;
  FTimeLabel.Visible := Shown;
  FItemsLabel.Visible := Shown;
  if Shown then
    ToggleTop := ToggleTopExpanded
  else
    ToggleTop := ToggleTopCollapsed;
  FDetailsToggle.SetBounds(Margin - 4, ToggleTop, ToggleWidth, ButtonHeight);
  if ClientHeight <> ToggleTop + ButtonHeight + BottomRoom then
    SetClientSize(DialogWidth, ToggleTop + ButtonHeight + BottomRoom);
end;

procedure TProgressDialog.DetailsToggled(Sender: TControl);
begin
  PlaceDetails;
end;

function TProgressDialog.GetDetailsShown: Boolean;
begin
  Result := FDetailsToggle.Expanded;
end;

procedure TProgressDialog.SetDetailsShown(Value: Boolean);
begin
  if Value = FDetailsToggle.Expanded then
    Exit;
  FDetailsToggle.Expanded := Value;
  PlaceDetails;
end;

procedure TProgressDialog.ShowPercent;
begin
  if FCancelled then
    FPercentLabel.Text := 'Cancelling...'
  else if FPaused then
    FPercentLabel.Text := 'Paused - ' + IntToStr(FPercent) + '% complete'
  else
    FPercentLabel.Text := IntToStr(FPercent) + '% complete';
end;

procedure TProgressDialog.UpdateProgress(BytesDone, BytesTotal: QWord; ItemsDone, ItemsTotal: LongInt;
  const CurrentName: string);
begin
  UpdateProgressAt(UptimeMilliseconds, BytesDone, BytesTotal, ItemsDone, ItemsTotal, CurrentName);
end;

procedure TProgressDialog.UpdateProgressAt(TimeMilliseconds: QWord; BytesDone, BytesTotal: QWord; ItemsDone,
  ItemsTotal: LongInt; const CurrentName: string);
var
  ItemsLeft: LongInt;
  BytesLeft: QWord;
begin
  if not FPaused then
    FMeter.AddSample(TimeMilliseconds, BytesDone, BytesTotal);
  { Bytes give the share when there are any to speak of, items else. }
  if BytesTotal > 0 then
    FPercent := PercentDone(BytesDone, BytesTotal)
  else if ItemsTotal > 0 then
    FPercent := PercentDone(ItemsDone, ItemsTotal)
  else
    FPercent := 0;
  if (BytesTotal > 0) and (BytesDone < BytesTotal) then
    FBar.Position := Round(BytesDone / BytesTotal * BarSteps)
  else
    FBar.Position := FPercent * (BarSteps div 100);
  ShowPercent;
  FSpeedLabel.Text := 'Speed: ' + TransferSpeedText(FMeter.BytesPerSecond);
  FNameLabel.Text := 'Name: ' + CurrentName;
  if FPaused then
    FTimeLabel.Text := 'Time remaining: Paused'
  else
    FTimeLabel.Text := 'Time remaining: ' + TimeRemainingText(FMeter.SecondsRemaining(BytesDone, BytesTotal));
  ItemsLeft := ItemsTotal - ItemsDone;
  if ItemsLeft < 0 then
    ItemsLeft := 0;
  BytesLeft := 0;
  if BytesTotal > BytesDone then
    BytesLeft := BytesTotal - BytesDone;
  FItemsLabel.Text := 'Items remaining: ' + ItemsRemainingText(ItemsLeft, BytesLeft);
  FGraph.Invalidate;
end;

procedure TProgressDialog.SetPaused(Value: Boolean);
begin
  if (Value = FPaused) or FCancelled then
    Exit;
  FPaused := Value;
  { The time paused does not count towards the speed. }
  FMeter.SkipGap;
  if FPaused then
    FPauseButton.Text := 'Resume'
  else
    FPauseButton.Text := 'Pause';
  ShowPercent;
  if Assigned(FOnPauseChanged) then
    FOnPauseChanged(Self, FPaused);
end;

procedure TProgressDialog.PauseClicked(Sender: TControl);
begin
  SetPaused(not FPaused);
end;

procedure TProgressDialog.Cancel;
begin
  if FCancelled then
    Exit;
  FCancelled := True;
  FPauseButton.Enabled := False;
  FCancelButton.Enabled := False;
  ShowPercent;
  if Assigned(FOnCancel) then
    FOnCancel(Self);
end;

procedure TProgressDialog.CancelClicked(Sender: TControl);
begin
  Cancel;
end;

procedure TProgressDialog.CloseRequested;
begin
  Cancel;
end;

function TProgressDialog.PauseButtonBounds: TRectangle;
begin
  Result := FPauseButton.PixelBounds;
end;

function TProgressDialog.CancelButtonBounds: TRectangle;
begin
  Result := FCancelButton.PixelBounds;
end;

function TProgressDialog.DetailsToggleBounds: TRectangle;
begin
  Result := FDetailsToggle.PixelBounds;
end;

end.

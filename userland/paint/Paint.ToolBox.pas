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
  The tool box: a button for every tool, flowing in rows as wide as the
  box is (a flow layout panel), the current one held down, and under
  them the current tool's options in a table, one under another: its
  size, how its shapes are filled, the fill's tolerance, the text's
  font (only those the tool takes are shown). Each button has a hint;
  the options have captions with mnemonics, so the keyboard reaches
  them (the Tools menu picks the tools).
}
unit Paint.ToolBox;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base,
  Controls.Panels,
  Controls.FlowPanel,
  Controls.TablePanel,
  Controls.ToolBar,
  Controls.Labels,
  Controls.Buttons,
  Controls.ComboBox,
  Controls.NumericUpDown,
  Paint.ToolKinds,
  Paint.Session;

type
  TToolChosenEvent = procedure(Kind: TToolKind) of object;
  TToolBoxEvent = procedure of object;

  { A tool's button, its picture drawn (Paint.ToolIcons). }
  TToolPictureButton = class(TToolButton)
  private
    FKind: TToolKind;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    property Kind: TToolKind read FKind write FKind;
  end;

  TToolBox = class(TPanel)
  private
    FSession: TPaintSession;
    FKind: TToolKind;
    FButtons: array[TToolKind] of TToolPictureButton;
    FOptions: TTableLayoutPanel;
    FSizeLabel: TLabel;
    FSizeBox: TNumericUpDown;
    FFillLabel: TLabel;
    FFillBox: TComboBox;
    FToleranceLabel: TLabel;
    FToleranceBox: TNumericUpDown;
    FFontButton: TButton;
    FShowing: Boolean;
    FOnToolChosen: TToolChosenEvent;
    FOnOptionsChanged: TToolBoxEvent;
    FOnFontWanted: TToolBoxEvent;
    procedure BuildButtons;
    procedure BuildOptions;
    function AddCaption(const Caption: string): TLabel;
    procedure ButtonClicked(Sender: TControl);
    procedure SizeChanged(Sender: TControl);
    procedure FillChanged(Sender: TControl);
    procedure ToleranceChanged(Sender: TControl);
    procedure FontClicked(Sender: TControl);
    procedure OptionsChanged;
  public
    constructor Create(AParent: TControl); override;
    procedure AttachSession(ASession: TPaintSession);
    { Shows Kind as the current tool, with its options. }
    procedure ShowTool(Kind: TToolKind);
    { The options as the session's settings are now. }
    procedure ShowOptions;
    function ButtonOf(Kind: TToolKind): TToolPictureButton;
    property OnToolChosen: TToolChosenEvent read FOnToolChosen write FOnToolChosen;
    property OnOptionsChanged: TToolBoxEvent read FOnOptionsChanged write FOnOptionsChanged;
    property OnFontWanted: TToolBoxEvent read FOnFontWanted write FOnFontWanted;
  end;

implementation

uses
  Drawing.Rectangles,
  Windowing.Connection,
  Windowing.Theme,
  Controls.LayoutRules,
  Controls.TableArrangement,
  Paint.ShapeDrawing,
  Paint.ToolIcons;

const
  { Logical units. }
  ButtonSide = 26;
  IconSide = 16;
  OptionsGap = 6;
  FillStyleCaptions: array[TFillStyle] of string = ('Outline', 'Fill', 'Outline and fill');

procedure TToolPictureButton.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Side: LongInt;
  Shift: LongInt;
begin
  inherited Paint(Canvas);
  Side := Scaled(IconSide);
  Shift := 0;
  if Down then
    Shift := 1;
  Box := MakeRectangle((RectangleWidth(PixelBounds) - Side) div 2 + Shift,
    (RectangleHeight(PixelBounds) - Side) div 2 + Shift, Side, Side);
  DrawToolIcon(Canvas, FKind, Box, Theme.FaceText);
end;

constructor TToolBox.Create(AParent: TControl);
begin
  inherited Create(AParent);
  ContentPadding := UniformSpacing(2);
  BuildButtons;
  BuildOptions;
end;

procedure TToolBox.BuildButtons;
var
  Flow: TFlowLayoutPanel;
  Kind: TToolKind;
  Button: TToolPictureButton;
begin
  Flow := TFlowLayoutPanel.Create(Self);
  Flow.Align := AlignTop;
  Flow.AutoSize := True;
  for Kind := Low(TToolKind) to High(TToolKind) do
  begin
    Button := TToolPictureButton.Create(Flow);
    Button.Kind := Kind;
    Button.IsToggle := True;
    Button.SetBounds(0, 0, ButtonSide, ButtonSide);
    Button.Margins := UniformSpacing(1);
    Button.Hint := ToolHints[Kind];
    Button.OnClick := @ButtonClicked;
    FButtons[Kind] := Button;
  end;
end;

function TToolBox.AddCaption(const Caption: string): TLabel;
begin
  Result := TLabel.Create(FOptions);
  Result.Text := Caption;
  Result.AutoSize := True;
  Result.Anchors := [akLeft];
  Result.Margins := MakeSpacing(0, OptionsGap, 0, 1);
end;

procedure TToolBox.BuildOptions;
var
  Style: TFillStyle;
begin
  FOptions := TTableLayoutPanel.Create(Self);
  FOptions.Align := AlignTop;
  FOptions.AutoSize := True;
  FOptions.DockOrder := 1;
  FOptions.AddColumn(TrackPercent, 100);
  FSizeLabel := AddCaption('Si&ze:');
  FSizeBox := TNumericUpDown.Create(FOptions);
  FSizeBox.AutoSize := True;
  FSizeBox.Anchors := [akLeft, akRight];
  FSizeBox.SetRange(SmallestToolSize, LargestToolSize);
  FSizeBox.OnValueChanged := @SizeChanged;
  FFillLabel := AddCaption('Sha&pe fill:');
  FFillBox := TComboBox.Create(FOptions);
  FFillBox.AutoSize := True;
  FFillBox.Anchors := [akLeft, akRight];
  for Style := Low(TFillStyle) to High(TFillStyle) do
    FFillBox.Items.Add(FillStyleCaptions[Style]);
  FFillBox.OnChange := @FillChanged;
  FToleranceLabel := AddCaption('To&lerance (%):');
  FToleranceBox := TNumericUpDown.Create(FOptions);
  FToleranceBox.AutoSize := True;
  FToleranceBox.Anchors := [akLeft, akRight];
  FToleranceBox.SetRange(0, 100);
  FToleranceBox.OnValueChanged := @ToleranceChanged;
  FFontButton := TButton.Create(FOptions);
  FFontButton.Text := 'Fo&nt...';
  FFontButton.AutoSize := True;
  FFontButton.Anchors := [akLeft, akRight];
  FFontButton.Margins := MakeSpacing(0, OptionsGap, 0, 0);
  FFontButton.OnClick := @FontClicked;
end;

procedure TToolBox.AttachSession(ASession: TPaintSession);
begin
  FSession := ASession;
  ShowOptions;
end;

function TToolBox.ButtonOf(Kind: TToolKind): TToolPictureButton;
begin
  Result := FButtons[Kind];
end;

procedure TToolBox.ShowTool(Kind: TToolKind);
var
  Each: TToolKind;
begin
  FKind := Kind;
  for Each := Low(TToolKind) to High(TToolKind) do
    FButtons[Each].Down := Each = Kind;
  ShowOptions;
end;

procedure TToolBox.ShowOptions;
var
  Options: TToolOptionSet;
begin
  Options := ToolOptions(FKind);
  FSizeLabel.Visible := OptionSize in Options;
  FSizeBox.Visible := OptionSize in Options;
  FFillLabel.Visible := OptionFillStyle in Options;
  FFillBox.Visible := OptionFillStyle in Options;
  FToleranceLabel.Visible := OptionTolerance in Options;
  FToleranceBox.Visible := OptionTolerance in Options;
  FFontButton.Visible := OptionFont in Options;
  if FSession = nil then
    Exit;
  FShowing := True;
  try
    FSizeBox.Value := FSession.ToolSize(FKind);
    FFillBox.ItemIndex := Ord(FSession.Settings.FillStyle);
    FToleranceBox.Value := FSession.Settings.TolerancePercent;
  finally
    FShowing := False;
  end;
end;

procedure TToolBox.ButtonClicked(Sender: TControl);
begin
  { Held down whatever the click did; the window makes it the tool. }
  ShowTool(TToolPictureButton(Sender).Kind);
  if Assigned(FOnToolChosen) then
    FOnToolChosen(TToolPictureButton(Sender).Kind);
end;

procedure TToolBox.OptionsChanged;
begin
  if Assigned(FOnOptionsChanged) then
    FOnOptionsChanged();
end;

procedure TToolBox.SizeChanged(Sender: TControl);
begin
  if FShowing or (FSession = nil) then
    Exit;
  FSession.Settings.Sizes[FKind] := FSizeBox.IntegerValue;
  OptionsChanged;
end;

procedure TToolBox.FillChanged(Sender: TControl);
begin
  if FShowing or (FSession = nil) or (FFillBox.ItemIndex < 0) then
    Exit;
  FSession.Settings.FillStyle := TFillStyle(FFillBox.ItemIndex);
  OptionsChanged;
end;

procedure TToolBox.ToleranceChanged(Sender: TControl);
begin
  if FShowing or (FSession = nil) then
    Exit;
  FSession.Settings.TolerancePercent := FToleranceBox.IntegerValue;
  OptionsChanged;
end;

procedure TToolBox.FontClicked(Sender: TControl);
begin
  if Assigned(FOnFontWanted) then
    FOnFontWanted();
end;

end.

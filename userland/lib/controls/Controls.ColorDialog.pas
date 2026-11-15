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
  The colour dialog: a user picks one of the basic colours or mixes
  one from red, green and blue.

  The basic colours are a grid of swatches; a click on one takes it.
  Each of red, green and blue has a scroll bar and a box for its number
  (0 to 255), kept in step: moving one changes the other, and both
  change the colour. A larger swatch shows the colour as it is now.

  ChooseColor does it in one call; TColorDialog is there for a program
  that wants more (where the swatches are, say).
}
unit Controls.ColorDialog;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Canvas,
  Controls.Base,
  Controls.EditBox,
  Controls.ScrollBar,
  Controls.CommonDialogs;

const
  BasicColorColumns = 8;
  BasicColorRows = 4;
  BasicColorCount = BasicColorColumns * BasicColorRows;

type
  TColorChannel = (ChannelRed, ChannelGreen, ChannelBlue);

  { A swatch: a colour in a sunken frame, outlined when it is the one
    chosen; clicking it is announced (OnClick). }
  TColorSwatch = class(TControl)
  private
    FColor: TColor;
    FChosen: Boolean;
    procedure SetColor(Value: TColor);
    procedure SetChosen(Value: Boolean);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  public
    property Color: TColor read FColor write SetColor;
    property Chosen: Boolean read FChosen write SetChosen;
  end;

  TColorDialog = class(TCommonDialog)
  private
    FColor: TColor;
    FUpdating: Boolean;
    FBasicSwatches: array[0..BasicColorCount - 1] of TColorSwatch;
    FScrollBars: array[TColorChannel] of TScrollBar;
    FNumberEdits: array[TColorChannel] of TEditBox;
    FPreview: TColorSwatch;
    procedure BuildControls;
    procedure BasicSwatchClicked(Sender: TControl);
    procedure ScrollBarChanged(Sender: TControl);
    procedure NumberChanged(Sender: TControl);
    function ChannelValue(Channel: TColorChannel): Byte;
    procedure SetChannel(Channel: TColorChannel; Value: Byte);
    procedure SetColor(Value: TColor);
    function GetBasicSwatch(Index: LongInt): TColorSwatch;
  public
    constructor CreateColorDialog(const ATitle: string; InitialColor: TColor);
    { The colour chosen (opaque). }
    property Color: TColor read FColor write SetColor;
    property BasicSwatches[Index: LongInt]: TColorSwatch read GetBasicSwatch;
    property Preview: TColorSwatch read FPreview;
  end;

{ The basic colour at Index (0 to BasicColorCount - 1). }
function BasicColor(Index: LongInt): TColor;
{ Shows a colour dialog starting at Color; True and the colour chosen
  in Color if OK ended it. }
function ChooseColor(var Color: TColor): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Labels;

const
  { Row by row: strong colours, light ones, dark ones, and greys. }
  BasicColors: array[0..BasicColorCount - 1] of TColor = (
    $FFFF0000, $FFFF8000, $FFFFFF00, $FF00FF00, $FF00FFFF, $FF0000FF, $FF8000FF, $FFFF00FF,
    $FFFF8080, $FFFFC080, $FFFFFF80, $FF80FF80, $FF80FFFF, $FF8080FF, $FFC080FF, $FFFF80FF,
    $FF800000, $FF804000, $FF808000, $FF008000, $FF008080, $FF000080, $FF400080, $FF800080,
    $FF000000, $FF202020, $FF404040, $FF606060, $FF808080, $FFA0A0A0, $FFC0C0C0, $FFFFFFFF);
  ChannelNames: array[TColorChannel] of string = ('Red:', 'Green:', 'Blue:');

  DialogWidth = 360;
  DialogHeight = 252;
  SwatchWidth = 24;
  SwatchHeight = 20;
  SwatchGap = 4;
  GridTop = 26;
  ChannelTop = 128;
  ChannelSpacing = 28;
  ChannelLabelWidth = 44;
  ChannelScrollWidth = 132;
  ChannelEditWidth = 44;
  FieldHeight = 22;
  PreviewLeft = 248;
  PreviewWidth = 104;
  PreviewHeight = 92;
  HighestValue = 255;

function BasicColor(Index: LongInt): TColor;
begin
  Result := BasicColors[Index];
end;

{ --- TColorSwatch ---------------------------------------------------------- }

procedure TColorSwatch.SetColor(Value: TColor);
begin
  if FColor = Value then
    Exit;
  FColor := Value;
  Invalidate;
end;

procedure TColorSwatch.SetChosen(Value: Boolean);
begin
  if FChosen = Value then
    Exit;
  FChosen := Value;
  Invalidate;
end;

procedure TColorSwatch.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  DrawBevel(Canvas, Box, SunkenThemeBevel);
  FillRectangle(Canvas, InflateRectangle(Box, -2), FColor);
  { The chosen one is ringed in the face text colour, a pixel outside
    the colour, so it shows whatever the colour is. }
  if FChosen then
    DrawRectangleOutline(Canvas, Box, Theme.FaceText);
end;

procedure TColorSwatch.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if (Button = ButtonLeft) and RectangleContainsPoint(MakeRectangle(0, 0, RectangleWidth(PixelBounds),
    RectangleHeight(PixelBounds)), X, Y) then
    Click;
end;

{ --- TColorDialog ---------------------------------------------------------- }

constructor TColorDialog.CreateColorDialog(const ATitle: string; InitialColor: TColor);
begin
  inherited CreateDialog(ATitle, DialogWidth, DialogHeight);
  BuildControls;
  { Different from any colour, so the first SetColor updates everything. }
  FColor := 0;
  SetColor(InitialColor);
end;

procedure TColorDialog.BuildControls;
var
  Caption: TLabel;
  Index: LongInt;
  Channel: TColorChannel;
  Top: LongInt;
begin
  Caption := TLabel.Create(Root);
  Caption.Text := 'Basic colours:';
  Caption.SetBounds(DialogMargin, DialogMargin, 200, 16);
  for Index := 0 to BasicColorCount - 1 do
  begin
    FBasicSwatches[Index] := TColorSwatch.Create(Root);
    FBasicSwatches[Index].Color := BasicColors[Index];
    FBasicSwatches[Index].Tag := Index;
    FBasicSwatches[Index].SetBounds(DialogMargin + (Index mod BasicColorColumns) * (SwatchWidth + SwatchGap),
      GridTop + (Index div BasicColorColumns) * (SwatchHeight + SwatchGap), SwatchWidth, SwatchHeight);
    FBasicSwatches[Index].OnClick := @BasicSwatchClicked;
  end;
  for Channel := Low(TColorChannel) to High(TColorChannel) do
  begin
    Top := ChannelTop + Ord(Channel) * ChannelSpacing;
    Caption := TLabel.Create(Root);
    Caption.Text := ChannelNames[Channel];
    Caption.SetBounds(DialogMargin, Top, ChannelLabelWidth, FieldHeight);
    FScrollBars[Channel] := TScrollBar.Create(Root);
    FScrollBars[Channel].Kind := ScrollHorizontal;
    FScrollBars[Channel].Tag := Ord(Channel);
    { A page of 16 makes a click beside the thumb a big step; the range
      is widened by the page so the thumb reaches 255. }
    FScrollBars[Channel].SetRange(0, HighestValue + 16, 16);
    FScrollBars[Channel].SetBounds(DialogMargin + ChannelLabelWidth, Top + 2, ChannelScrollWidth,
      Theme.ScrollBarWidth);
    FScrollBars[Channel].OnChange := @ScrollBarChanged;
    FNumberEdits[Channel] := TEditBox.Create(Root);
    FNumberEdits[Channel].Tag := Ord(Channel);
    FNumberEdits[Channel].MaximumLength := 3;
    FNumberEdits[Channel].SetBounds(DialogMargin + ChannelLabelWidth + ChannelScrollWidth + SwatchGap * 2, Top,
      ChannelEditWidth, FieldHeight);
    FNumberEdits[Channel].OnChange := @NumberChanged;
  end;
  Caption := TLabel.Create(Root);
  Caption.Text := 'Colour:';
  Caption.SetBounds(PreviewLeft, DialogMargin, PreviewWidth, 16);
  FPreview := TColorSwatch.Create(Root);
  FPreview.SetBounds(PreviewLeft, GridTop, PreviewWidth, PreviewHeight);
  AddOkAndCancel(DialogWidth, DialogHeight);
end;

function TColorDialog.GetBasicSwatch(Index: LongInt): TColorSwatch;
begin
  Result := FBasicSwatches[Index];
end;

function TColorDialog.ChannelValue(Channel: TColorChannel): Byte;
begin
  case Channel of
    ChannelRed: Result := RedOf(FColor);
    ChannelGreen: Result := GreenOf(FColor);
  else
    Result := BlueOf(FColor);
  end;
end;

procedure TColorDialog.SetChannel(Channel: TColorChannel; Value: Byte);
begin
  case Channel of
    ChannelRed: SetColor(RgbColor(Value, GreenOf(FColor), BlueOf(FColor)));
    ChannelGreen: SetColor(RgbColor(RedOf(FColor), Value, BlueOf(FColor)));
    ChannelBlue: SetColor(RgbColor(RedOf(FColor), GreenOf(FColor), Value));
  end;
end;

procedure TColorDialog.SetColor(Value: TColor);
var
  Index: LongInt;
  Channel: TColorChannel;
  NumberText: string;
begin
  Value := WithAlpha(Value, 255);
  if Value = FColor then
    Exit;
  FColor := Value;
  { The controls are set from the colour; their own change events must
    not set it back meanwhile (a half-typed number would). }
  FUpdating := True;
  try
    for Index := 0 to BasicColorCount - 1 do
      FBasicSwatches[Index].Chosen := FBasicSwatches[Index].Color = FColor;
    for Channel := Low(TColorChannel) to High(TColorChannel) do
    begin
      FScrollBars[Channel].Position := ChannelValue(Channel);
      NumberText := IntToStr(ChannelValue(Channel));
      if FNumberEdits[Channel].Text <> NumberText then
        FNumberEdits[Channel].Text := NumberText;
    end;
    FPreview.Color := FColor;
  finally
    FUpdating := False;
  end;
end;

procedure TColorDialog.BasicSwatchClicked(Sender: TControl);
begin
  SetColor(FBasicSwatches[Sender.Tag].Color);
end;

procedure TColorDialog.ScrollBarChanged(Sender: TControl);
begin
  if not FUpdating then
    SetChannel(TColorChannel(Sender.Tag), FScrollBars[TColorChannel(Sender.Tag)].Position);
end;

procedure TColorDialog.NumberChanged(Sender: TControl);
var
  Value: LongInt;
begin
  if FUpdating then
    Exit;
  { An empty box or one being typed in stays as it is until it holds a
    number; numbers above 255 count as 255. }
  if not TryStrToInt(Trim(Sender.Text), Value) or (Value < 0) then
    Exit;
  if Value > HighestValue then
    Value := HighestValue;
  SetChannel(TColorChannel(Sender.Tag), Value);
end;

function ChooseColor(var Color: TColor): Boolean;
var
  Dialog: TColorDialog;
begin
  Dialog := TColorDialog.CreateColorDialog('Colour', Color);
  try
    Result := Dialog.Execute;
    if Result then
      Color := Dialog.Color;
  finally
    Dialog.Free;
  end;
end;

end.

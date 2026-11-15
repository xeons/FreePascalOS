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
  Check boxes and radio buttons: a box or circle and text after it.

  A check box toggles when clicked (or with Space). A radio button is
  one of the radio buttons that share its parent: checking it unchecks
  the others. Both announce a change (OnChange, NotifyChanged). Alt and
  the mnemonic ("&Remember") focuses one and toggles or checks it.
}
unit Controls.Toggles;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base;

type
  TToggle = class(TControl)
  private
    FChecked: Boolean;
    procedure SetChecked(Value: Boolean);
  protected
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure Toggle; virtual; abstract;
    procedure CheckedChanged; virtual;
    { Where the text goes, and the box or circle. }
    function MarkSize: LongInt;
    procedure PaintText(var Canvas: TCanvas);
  public
    constructor Create(AParent: TControl); override;
    function MatchesMnemonic(Character: LongWord): Boolean; override;
    procedure ActivateMnemonic(Character: LongWord); override;
    property Checked: Boolean read FChecked write SetChecked;
  end;

  TCheckBox = class(TToggle)
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure Toggle; override;
  end;

  TRadioButton = class(TToggle)
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure Toggle; override;
    procedure CheckedChanged; override;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Bevels,
  Drawing.Shapes,
  Drawing.SmoothShapes,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text;

constructor TToggle.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
end;

procedure TToggle.SetChecked(Value: Boolean);
begin
  if FChecked = Value then
    Exit;
  FChecked := Value;
  CheckedChanged;
  Invalidate;
  Changed;
end;

procedure TToggle.CheckedChanged;
begin
end;

procedure TToggle.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if (Button = ButtonLeft) and (X >= 0) and (Y >= 0) and (X < RectangleWidth(PixelBounds)) and
     (Y < RectangleHeight(PixelBounds)) then
  begin
    Toggle;
    Click;
  end;
end;

function TToggle.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := Code = KeySpace;
  if Result then
  begin
    Toggle;
    Click;
  end;
end;

function TToggle.MatchesMnemonic(Character: LongWord): Boolean;
begin
  Result := TextMatchesMnemonic(Character);
end;

procedure TToggle.ActivateMnemonic(Character: LongWord);
begin
  SetFocus;
  Toggle;
  Click;
end;

function TToggle.MarkSize: LongInt;
begin
  Result := Scaled(13);
end;

procedure TToggle.PaintText(var Canvas: TCanvas);
var
  Box: TRectangle;
  TextLeft: LongInt;
begin
  TextLeft := MarkSize + Scaled(5);
  Box := MakeRectangle(TextLeft, 0, RectangleWidth(PixelBounds) - TextLeft, RectangleHeight(PixelBounds));
  if Enabled then
    DrawMnemonicTextInBox(Canvas, ControlFace, Text, Box, AlignTextLeft, Theme.FaceText)
  else
    DrawDisabledMnemonicText(Canvas, ControlFace, Text, Box.Left, (RectangleHeight(Box) - TextHeight(ControlFace)) div 2);
  if Focused then
    DrawFocusFrame(Canvas, MakeRectangle(TextLeft - Scaled(2), (RectangleHeight(Box) - TextHeight(ControlFace)) div 2 - 1,
      MnemonicTextWidth(ControlFace, Text) + Scaled(4), TextHeight(ControlFace) + 2), Theme.FaceText);
end;

procedure TCheckBox.Toggle;
begin
  Checked := not Checked;
end;

procedure TCheckBox.Paint(var Canvas: TCanvas);
var
  Mark: TRectangle;
  Size: LongInt;
  Thickness: LongInt;
  Offset: LongInt;
  Tick: TRectangle;
begin
  Size := MarkSize;
  Mark := MakeRectangle(0, (RectangleHeight(PixelBounds) - Size) div 2, Size, Size);
  FillRectangle(Canvas, Mark, Theme.Field);
  DrawBevel(Canvas, Mark, SunkenThemeBevel);
  if Checked then
  begin
    { A tick: from the left middle down to a third across, then up to
      the top right; Thickness pixels thick. }
    Tick := InflateRectangle(Mark, -Scaled(3));
    Thickness := Scaled(2);
    for Offset := 0 to Thickness - 1 do
    begin
      DrawLine(Canvas, Tick.Left, Tick.Top + RectangleHeight(Tick) div 2 + Offset,
        Tick.Left + RectangleWidth(Tick) div 3, Tick.Bottom - Thickness + Offset, Theme.FieldText);
      DrawLine(Canvas, Tick.Left + RectangleWidth(Tick) div 3, Tick.Bottom - Thickness + Offset,
        Tick.Right - 1, Tick.Top + Offset, Theme.FieldText);
    end;
  end;
  PaintText(Canvas);
end;

procedure TRadioButton.Toggle;
begin
  Checked := True;
end;

procedure TRadioButton.CheckedChanged;
var
  Index: LongInt;
  Sibling: TControl;
begin
  if not Checked or (Parent = nil) then
    Exit;
  for Index := 0 to Parent.ChildCount - 1 do
  begin
    Sibling := Parent.Children[Index];
    if (Sibling <> Self) and (Sibling is TRadioButton) then
      TRadioButton(Sibling).Checked := False;
  end;
end;

procedure TRadioButton.Paint(var Canvas: TCanvas);
var
  Mark: TRectangle;
  Size: LongInt;
begin
  Size := MarkSize;
  Mark := MakeRectangle(0, (RectangleHeight(PixelBounds) - Size) div 2, Size, Size);
  { Anti-aliased, each ring blended over the one outside it, so the
    circle is round at any size. }
  FillSmoothEllipse(Canvas, Mark, Theme.Shadow);
  FillSmoothEllipse(Canvas, InflateRectangle(Mark, -1), Theme.DarkShadow);
  FillSmoothEllipse(Canvas, InflateRectangle(Mark, -2), Theme.Field);
  if Checked then
    FillSmoothEllipse(Canvas, InflateRectangle(Mark, -(Size div 3)), Theme.FieldText);
  PaintText(Canvas);
end;

end.

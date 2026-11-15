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
  Labels: a line of text, aligned within the label, on the face colour.

  A label's mnemonic ("&Name:") focuses the control made after it that
  takes the focus: the edit box it names. A label of other text (a
  message) is shown as it is, ampersands and all: ShowsMnemonic False.
}
unit Controls.Labels;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base,
  Controls.Text;

type
  TLabel = class(TControl)
  private
    FAlignment: THorizontalAlignment;
    FShowsMnemonic: Boolean;
    procedure SetAlignment(Value: THorizontalAlignment);
    procedure SetShowsMnemonic(Value: Boolean);
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    function MatchesMnemonic(Character: LongWord): Boolean; override;
    procedure ActivateMnemonic(Character: LongWord); override;
    property Alignment: THorizontalAlignment read FAlignment write SetAlignment;
    { True (the default): an ampersand in the text marks the mnemonic. }
    property ShowsMnemonic: Boolean read FShowsMnemonic write SetShowsMnemonic;
  end;

implementation

uses
  Drawing.Rectangles,
  Windowing.Theme;

constructor TLabel.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FShowsMnemonic := True;
end;

procedure TLabel.SetShowsMnemonic(Value: Boolean);
begin
  FShowsMnemonic := Value;
  Invalidate;
end;

procedure TLabel.SetAlignment(Value: THorizontalAlignment);
begin
  FAlignment := Value;
  Invalidate;
end;

function TLabel.MatchesMnemonic(Character: LongWord): Boolean;
begin
  Result := FShowsMnemonic and TextMatchesMnemonic(Character);
end;

procedure TLabel.ActivateMnemonic(Character: LongWord);
begin
  if Host <> nil then
    Host.FocusControlAfter(Self);
end;

procedure TLabel.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if not FShowsMnemonic and Enabled then
    DrawTextInBox(Canvas, ControlFace, Text, Box, FAlignment, Theme.FaceText)
  else if not FShowsMnemonic then
    DrawDisabledText(Canvas, ControlFace, Text, 0, (RectangleHeight(Box) - TextHeight(ControlFace)) div 2)
  else if Enabled then
    DrawMnemonicTextInBox(Canvas, ControlFace, Text, Box, FAlignment, Theme.FaceText)
  else
    DrawDisabledMnemonicText(Canvas, ControlFace, Text, 0, (RectangleHeight(Box) - TextHeight(ControlFace)) div 2);
end;

end.

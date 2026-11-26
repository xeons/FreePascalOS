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
  Ellipses at the ends of lines (CSS Overflow 4):

  - text-overflow: ellipsis on a block container whose overflow clips:
    each line that runs past the content box's end edge loses the
    characters and atomic inlines that the ellipsis needs room for, and
    gets the ellipsis ("…" in the container's font and colour);
  - legacy line clamping: display: -webkit-box (or -webkit-inline-box)
    with -webkit-box-orient: vertical and -webkit-line-clamp: N is a
    block container (as in other browsers, not a flexbox) whose lines
    after the Nth are dropped; its height is that of N lines and the
    Nth line ends with an ellipsis.

  The ellipsis is recorded in the inline content (TLineEllipsis) for
  painting; hidden fragments are marked Clipped.
}
unit Web.Layout.LineClamp;

{$mode objfpc}
{$H+}

interface

uses
  Css.ComputedStyle, Web.Layout.Boxes;

const
  EllipsisText = #$E2#$80#$A6;

{ N of -webkit-line-clamp for a legacy line clamping box, 0 for any other. }
function LineClampOf(Style: TCssComputedStyle): Integer;
{ Lines after the clamp dropped (ContentHeight becomes the height of the
  ones kept) and an ellipsis on the last one. }
procedure ClampLines(Box: TLayoutBox; Clamp: Integer; var ContentHeight: Single);
{ text-overflow: ellipsis on the lines that overflow the content box. }
procedure ApplyTextOverflow(Box: TLayoutBox);

implementation

uses
  Css.ComputedValues, Css.PropertyIds, Css.Keywords, Css.Values, Web.Layout.Values, Web.Text.FontInstances;

const
  Epsilon = 0.01;

function LineClampOf(Style: TCssComputedStyle): Integer;
var
  Value: PCssComputedValue;
begin
  Result := 0;
  if not KeywordIn(Style.Keyword(cpDisplay), [kwWebkitBox, kwWebkitInlineBox]) then
    Exit;
  if not KeywordIn(Style.Keyword(cpWebkitBoxOrient), [kwVertical, kwBlockAxis]) then
    Exit;
  Value := Style.Value(cpWebkitLineClamp);
  if (Value^.Kind in [cvInteger, cvNumber]) and (Value^.Number >= 1) then
    Result := Round(Value^.Number);
end;

{ Whether text-overflow's end side value is ellipsis. }
function EndSideIsEllipsis(Style: TCssComputedStyle): Boolean;
var
  Value: PCssComputedValue;
  Data: TCssValue;
begin
  Value := Style.Value(cpTextOverflow);
  if Value^.Kind = cvKeyword then
    Exit(TCssKeyword(Value^.Keyword) = kwEllipsis);
  Result := False;
  if (Value^.Kind <> cvValue) or (Value^.Data = nil) then
    Exit;
  Data := Value^.Data;
  if (Data.Kind = vkList) and (Data.Count > 0) then
    Data := Data.Items[Data.Count - 1];
  Result := Data.IsKeyword(kwEllipsis);
end;

{ The start of the UTF-8 character before byte Position (1-based). }
function PreviousCharacterStart(const Text: string; Position: Integer): Integer;
begin
  Result := Position - 1;
  while (Result > 1) and ((Ord(Text[Result]) and $C0) = $80) do
    Dec(Result);
end;

{ How many bytes of the fragment's text, from its start, fit in Room. }
function FittingLength(Text: TTextBox; Start, Length: Integer; Room: Single): Integer;
var
  Font: TTextFont;
  Stop: Integer;
begin
  Font := TextFontOf(Text.Style);
  Stop := Start + Length;
  while Stop > Start do
  begin
    if Font.MeasureText(Text.Text, Start, Stop - Start) <= Room + Epsilon then
      Exit(Stop - Start);
    Stop := PreviousCharacterStart(Text.Text, Stop);
  end;
  Result := 0;
end;

{ Makes room for the ellipsis before Limit on the line and records it. }
procedure PlaceEllipsis(Box: TLayoutBox; LineIndex: Integer; Limit: Single);
var
  Content: TInlineContent;
  Line: TLineBoxRecord;
  Index, Kept: Integer;
  Fragment: PLineFragment;
  EllipsisWidth, EllipsisX, Room: Single;
  Text: TTextBox;
begin
  Content := Box.Inline;
  Line := Content.Lines[LineIndex];
  EllipsisWidth := TextFontOf(Box.Style).MeasureText(EllipsisText, 1, Length(EllipsisText));
  Room := Limit - EllipsisWidth;
  EllipsisX := Box.ContentLeft;
  for Index := Line.FirstFragment + Line.FragmentCount - 1 downto Line.FirstFragment do
  begin
    Fragment := @Content.Fragments[Index];
    if Fragment^.Kind = fkLineBreak then
      Continue;
    if Fragment^.X + Fragment^.Width <= Room + Epsilon then
    begin
      if Fragment^.Kind <> fkInlineBox then
      begin
        EllipsisX := Fragment^.X + Fragment^.Width;
        Break;
      end;
      Continue;
    end;
    case Fragment^.Kind of
      fkText:
        begin
          Text := TTextBox(Fragment^.Box);
          Kept := FittingLength(Text, Fragment^.TextStart, Fragment^.TextLength, Room - Fragment^.X);
          if Kept > 0 then
          begin
            Fragment^.TextLength := Kept;
            Fragment^.Width := TextFontOf(Text.Style).MeasureText(Text.Text, Fragment^.TextStart, Kept);
            EllipsisX := Fragment^.X + Fragment^.Width;
            Break;
          end;
          Fragment^.Clipped := True;
        end;
      fkInlineBox:
        if Fragment^.X >= Room then
          Fragment^.Clipped := True
        else
        begin
          Fragment^.Width := Room - Fragment^.X;
          Fragment^.HasEnd := False;
        end;
    else
      Fragment^.Clipped := True;
    end;
  end;
  if Content.EllipsisCount >= Length(Content.Ellipses) then
    SetLength(Content.Ellipses, Content.EllipsisCount * 2 + 2);
  Content.Ellipses[Content.EllipsisCount].X := EllipsisX;
  Content.Ellipses[Content.EllipsisCount].Baseline := Line.Baseline;
  Inc(Content.EllipsisCount);
end;

function LineEnd(Content: TInlineContent; LineIndex: Integer): Single;
var
  Index: Integer;
  Line: TLineBoxRecord;
  Fragment: PLineFragment;
begin
  Result := 0;
  Line := Content.Lines[LineIndex];
  for Index := Line.FirstFragment to Line.FirstFragment + Line.FragmentCount - 1 do
  begin
    Fragment := @Content.Fragments[Index];
    if (Fragment^.Kind <> fkLineBreak) and (Fragment^.X + Fragment^.Width > Result) then
      Result := Fragment^.X + Fragment^.Width;
  end;
end;

{ Whether the line already ends with an ellipsis (a clamped last line). }
function HasEllipsis(Content: TInlineContent; LineIndex: Integer): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to Content.EllipsisCount - 1 do
    if Content.Ellipses[Index].Baseline = Content.Lines[LineIndex].Baseline then
      Exit(True);
  Result := False;
end;

procedure ClampLines(Box: TLayoutBox; Clamp: Integer; var ContentHeight: Single);
var
  Content: TInlineContent;
  Last: TLineBoxRecord;
begin
  Content := Box.Inline;
  if (Content = nil) or (Content.LineCount <= Clamp) then
    Exit;
  Last := Content.Lines[Clamp - 1];
  Content.LineCount := Clamp;
  Content.FragmentCount := Last.FirstFragment + Last.FragmentCount;
  ContentHeight := Last.Top + Last.Height - Box.ContentTop;
  Box.LastBaseline := Last.Baseline;
  PlaceEllipsis(Box, Clamp - 1, Box.ContentLeft + Box.ContentWidth);
end;

procedure ApplyTextOverflow(Box: TLayoutBox);
var
  Content: TInlineContent;
  LineIndex: Integer;
  Limit: Single;
begin
  Content := Box.Inline;
  if (Content = nil) or not OverflowClips(Box.Style) or not EndSideIsEllipsis(Box.Style) then
    Exit;
  Limit := Box.ContentLeft + Box.ContentWidth;
  for LineIndex := 0 to Content.LineCount - 1 do
    if (LineEnd(Content, LineIndex) > Limit + Epsilon) and not HasEllipsis(Content, LineIndex) then
      PlaceEllipsis(Box, LineIndex, Limit);
end;

end.

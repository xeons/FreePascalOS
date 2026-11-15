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
  The view under the multi-line edit box: lines of text shown in a face,
  scrolled, with a caret and a selection, and the caret's moves.

  The text is in rows: a line is one row, or several with word wrap
  (soft breaks at the box's width; Controls.TextLayout lays a line out).
  Scrolling, the scroll bar, the pointer and moving up and down go by
  rows; positions in the text stay a line and a character. How many
  rows each line takes is remembered (a line is laid out again only
  when it changes, the width or the face changes), so a long text
  scrolls without being measured again; the line laid out last is kept
  too, as the caret's moves ask for it often. Without word wrap the
  text scrolls sideways to keep the caret in view.

  The face is the theme's monospaced one unless SetFont picks another
  (a family, a size in points and bold or not), so it follows the
  display's DPI like every other. Controls.TextEdit adds the editing;
  ReplaceLines is the one way the text changes from there, so the rows
  remembered stay right.
}
unit Controls.TextView;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Canvas,
  Font.Faces,
  Windowing.Messages,
  Windowing.Fonts,
  Controls.Base,
  Controls.ScrollBar,
  Controls.TextPositions,
  Controls.TextLayout,
  Controls.TextSearch;

type
  { A line and one of its rows: a place in the rows of the text. }
  TRowPlace = record
    Line: LongInt;
    Row: LongInt;
  end;

  TTextView = class(TControl)
  private
    FScrollBar: TScrollBar;
    FTop: TRowPlace;
    FScrollX: LongInt;
    FWordWrap: Boolean;
    FFontFamily: TFontFamily;
    FFontPointTenths: LongWord;
    FFontBold: Boolean;
    { Rows of each line (-1: not laid out yet), for FRowFace at
      FRowWidth; only kept with word wrap. }
    FRowCounts: array of LongInt;
    FRowFace: PFontFace;
    FRowWidth: LongInt;
    { The line laid out last, and what for. }
    FCachedLayout: TLineLayout;
    FCachedLine: LongInt;
    FCachedGeneration: LongWord;
    FCachedFace: PFontFace;
    FCachedWidth: LongInt;
    { Counts changes to the text, the face and the width. }
    FGeneration: LongWord;
    FReportedCaret: TTextPosition;
    FOnCaretMoved: TControlEvent;
    procedure SetWordWrap(Value: Boolean);
    procedure EnsureRowCounts;
    procedure ForgetRows;
    function StoredRowCount(Line: LongInt): LongInt;
    function RowCountOfLine(Line: LongInt): LongInt;
    function TotalRows: LongInt;
    function RowIndexOf(const Place: TRowPlace): LongInt;
    function PlaceOfRowIndex(Index: LongInt): TRowPlace;
    function LastTopPlace: TRowPlace;
    procedure SetTop(Place: TRowPlace);
    procedure LinesChanged(Sender: TObject);
    procedure PaintRow(var Canvas: TCanvas; Face: PFontFace; Line: LongInt; const LineLayout: TLineLayout;
      Row, Top: LongInt);
  protected
    FLines: TStringList;
    FCaret: TTextPosition;
    FAnchor: TTextPosition;
    { The text is being changed by the control itself: FLines' OnChange
      is not about someone else's change. }
    FChanging: Boolean;
    { The X a run of moves up and down keeps to (-1: none yet). }
    FDesiredX: LongInt;
    function EditFace: PFontFace;
    function LineHeight: LongInt;
    function VisibleRows: LongInt;
    function TextLeft: LongInt;
    { The width rows wrap at (0: no word wrap). }
    function WrapWidth: LongInt;
    function LayoutOf(Line: LongInt): TLineLayout;
    function LineLength(Line: LongInt): LongInt;
    function PlaceOfCaret: TRowPlace;
    { Count rows on from Place (back if negative), stopping at the ends. }
    function StepRows(const Place: TRowPlace; Count: LongInt): TRowPlace;
    function PositionAt(X, Y: LongInt): TTextPosition;
    { The caret to (Line, Column), kept in the text; Extend keeps the
      anchor (a selection grows). }
    procedure MoveCaret(Line, Column: LongInt; Extend: Boolean);
    { Up or down Count rows, keeping to the same X. }
    procedure MoveCaretByRows(Count: LongInt; Extend: Boolean);
    { The start and end of the caret's row. }
    procedure MoveCaretToRowStart(Extend: Boolean);
    procedure MoveCaretToRowEnd(Extend: Boolean);
    { The caret was moved by the user (not by an edit). }
    procedure UserMovedCaret; virtual;
    { Painted as a field (white), not greyed. }
    function ShowsAsField: Boolean; virtual;
    { Tells OnCaretMoved if the caret is somewhere new. }
    procedure ReportCaret;
    procedure UpdateScrollBar;
    { Replaces the text from Start to Finish with Inserted (line feeds
      split it into lines); returns where it ends. Nothing else is done:
      the caller places the caret and shows the change. }
    function ReplaceLines(const Start, Finish: TTextPosition; const Inserted: string): TTextPosition;
    procedure Paint(var Canvas: TCanvas); override;
    procedure Wheel(Steps: LongInt); override;
    procedure Layout; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    procedure ScrollToCaret;
    function SelectionStart: TTextPosition;
    function SelectionEnd: TTextPosition;
    function HasSelection: Boolean;
    { Selects from Start to Finish, the caret at Finish, and shows it. }
    procedure SelectRange(const Start, Finish: TTextPosition);
    procedure SelectAll;
    function SelectedText: string;
    { The text from Start to Finish, lines joined with line feeds. }
    function TextBetween(Start, Finish: TTextPosition): string;
    { The whole text, lines joined with line feeds. }
    function AllText: string;
    procedure SetAllText(const Value: string); virtual;
    { The caret to the start of line Line (from 0), shown. }
    procedure GoToLine(Line: LongInt);
    { Finds Pattern after the selection (down) or before it (up) and
      selects it; False if there is no more. }
    function FindText(const Pattern: string; const Options: TSearchOptions): Boolean;
    { The face: a family, a size in tenths of a point, bold or not. }
    procedure SetFont(Family: TFontFamily; PointTenths: LongWord; Bold: Boolean);
    { How many rows the text takes (lines, without word wrap). }
    function RowCount: LongInt;
    { The row of its line the caret is in (0 without word wrap). }
    function CaretRow: LongInt;
    property Lines: TStringList read FLines;
    property CaretLine: LongInt read FCaret.Line;
    property CaretColumn: LongInt read FCaret.Column;
    property WordWrap: Boolean read FWordWrap write SetWordWrap;
    property FontFamily: TFontFamily read FFontFamily;
    property FontPointTenths: LongWord read FFontPointTenths;
    property FontBold: Boolean read FFontBold;
    { The caret moved (by a key, the pointer, an edit, or the program). }
    property OnCaretMoved: TControlEvent read FOnCaretMoved write FOnCaretMoved;
  end;

function MakeRowPlace(Line, Row: LongInt): TRowPlace;

implementation

uses
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Protocol,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text;

const
  { Rows the wheel scrolls by a step. }
  WheelRows = 3;
  { Pixels a selected line break shows as, logical units. }
  LineBreakWidth = 4;
  { Lines inserted or removed at once beyond which the list is built
    again rather than shifted a line at a time. }
  RebuildThreshold = 64;

function MakeRowPlace(Line, Row: LongInt): TRowPlace;
begin
  Result.Line := Line;
  Result.Row := Row;
end;

function PlaceBefore(const First, Second: TRowPlace): Boolean;
begin
  Result := (First.Line < Second.Line) or ((First.Line = Second.Line) and (First.Row < Second.Row));
end;

constructor TTextView.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  PointerShape := PointerTextBeam;
  FLines := TStringList.Create;
  FLines.Add('');
  FLines.OnChange := @LinesChanged;
  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Visible := False;
  FFontFamily := FontFamilyFixed;
  FFontPointTenths := Theme.TextPoints;
  FDesiredX := -1;
  FCachedLine := -1;
end;

destructor TTextView.Destroy;
begin
  FLines.Free;
  inherited Destroy;
end;

function TTextView.EditFace: PFontFace;
begin
  Result := FamilyFontFace(FFontFamily, FFontPointTenths, FFontBold);
end;

function TTextView.LineHeight: LongInt;
begin
  Result := TextHeight(EditFace);
  if Result < 1 then
    Result := 1;
end;

function TTextView.VisibleRows: LongInt;
begin
  Result := (RectangleHeight(PixelBounds) - 4) div LineHeight;
  if Result < 1 then
    Result := 1;
end;

function TTextView.TextLeft: LongInt;
begin
  Result := Scaled(4);
end;

function TTextView.WrapWidth: LongInt;
begin
  if not FWordWrap then
    Exit(0);
  { The scroll bar's room is always left, so rows do not wrap again as
    it comes and goes. }
  Result := RectangleWidth(PixelBounds) - 2 * TextLeft - Scaled(Theme.ScrollBarWidth) - 4;
  if Result < 1 then
    Result := 1;
end;

function TTextView.LayoutOf(Line: LongInt): TLineLayout;
var
  Face: PFontFace;
  Width: LongInt;
begin
  Face := EditFace;
  Width := WrapWidth;
  if (Line <> FCachedLine) or (FCachedGeneration <> FGeneration) or (FCachedFace <> Face) or
     (FCachedWidth <> Width) then
  begin
    FCachedLayout := LayOutLine(Face, FLines[Line], Width);
    FCachedLine := Line;
    FCachedGeneration := FGeneration;
    FCachedFace := Face;
    FCachedWidth := Width;
  end;
  Result := FCachedLayout;
end;

function TTextView.LineLength(Line: LongInt): LongInt;
begin
  Result := CountCharacters(FLines[Line]);
end;

{ --- Rows ------------------------------------------------------------------------------ }

procedure TTextView.ForgetRows;
var
  Index: LongInt;
begin
  SetLength(FRowCounts, FLines.Count);
  for Index := 0 to High(FRowCounts) do
    FRowCounts[Index] := -1;
  FRowFace := EditFace;
  FRowWidth := WrapWidth;
end;

{ The rows remembered are for the face and width there are now, and
  one per line. }
procedure TTextView.EnsureRowCounts;
begin
  if (Length(FRowCounts) <> FLines.Count) or (FRowFace <> EditFace) or (FRowWidth <> WrapWidth) then
    ForgetRows;
end;

{ The rows of Line with word wrap, once EnsureRowCounts has made sure
  what is remembered holds (loops over every line ask that once). }
function TTextView.StoredRowCount(Line: LongInt): LongInt;
begin
  if FRowCounts[Line] < 0 then
    FRowCounts[Line] := RowCountOfLayout(LayoutOf(Line));
  Result := FRowCounts[Line];
end;

function TTextView.RowCountOfLine(Line: LongInt): LongInt;
begin
  if not FWordWrap then
    Exit(1);
  EnsureRowCounts;
  Result := StoredRowCount(Line);
end;

function TTextView.TotalRows: LongInt;
var
  Line: LongInt;
begin
  if not FWordWrap then
    Exit(FLines.Count);
  EnsureRowCounts;
  Result := 0;
  for Line := 0 to FLines.Count - 1 do
    Result := Result + StoredRowCount(Line);
end;

function TTextView.RowCount: LongInt;
begin
  Result := TotalRows;
end;

function TTextView.RowIndexOf(const Place: TRowPlace): LongInt;
var
  Line: LongInt;
begin
  if not FWordWrap then
    Exit(Place.Line);
  EnsureRowCounts;
  Result := Place.Row;
  for Line := 0 to Place.Line - 1 do
    Result := Result + StoredRowCount(Line);
end;

function TTextView.PlaceOfRowIndex(Index: LongInt): TRowPlace;
var
  Line: LongInt;
begin
  if not FWordWrap then
    Exit(MakeRowPlace(Index, 0));
  EnsureRowCounts;
  Line := 0;
  while (Line < FLines.Count - 1) and (Index >= StoredRowCount(Line)) do
  begin
    Index := Index - StoredRowCount(Line);
    Inc(Line);
  end;
  if Index >= RowCountOfLine(Line) then
    Index := RowCountOfLine(Line) - 1;
  if Index < 0 then
    Index := 0;
  Result := MakeRowPlace(Line, Index);
end;

function TTextView.StepRows(const Place: TRowPlace; Count: LongInt): TRowPlace;
begin
  Result := Place;
  while Count > 0 do
  begin
    if Result.Row + 1 < RowCountOfLine(Result.Line) then
      Inc(Result.Row)
    else if Result.Line + 1 < FLines.Count then
      Result := MakeRowPlace(Result.Line + 1, 0)
    else
      Break;
    Dec(Count);
  end;
  while Count < 0 do
  begin
    if Result.Row > 0 then
      Dec(Result.Row)
    else if Result.Line > 0 then
      Result := MakeRowPlace(Result.Line - 1, RowCountOfLine(Result.Line - 1) - 1)
    else
      Break;
    Inc(Count);
  end;
end;

{ The top row with which the last row is at the bottom. }
function TTextView.LastTopPlace: TRowPlace;
var
  LastLine: LongInt;
begin
  LastLine := FLines.Count - 1;
  Result := StepRows(MakeRowPlace(LastLine, RowCountOfLine(LastLine) - 1), -(VisibleRows - 1));
end;

function TTextView.PlaceOfCaret: TRowPlace;
begin
  Result := MakeRowPlace(FCaret.Line, RowOfColumn(LayoutOf(FCaret.Line), FCaret.Column));
end;

function TTextView.CaretRow: LongInt;
begin
  Result := PlaceOfCaret.Row;
end;

{ --- Scrolling ---------------------------------------------------------------------------- }

procedure TTextView.SetTop(Place: TRowPlace);
var
  Limit: TRowPlace;
begin
  if Place.Line >= FLines.Count then
    Place := MakeRowPlace(FLines.Count - 1, 0);
  if Place.Line < 0 then
    Place := MakeRowPlace(0, 0);
  if Place.Row >= RowCountOfLine(Place.Line) then
    Place.Row := RowCountOfLine(Place.Line) - 1;
  if Place.Row < 0 then
    Place.Row := 0;
  Limit := LastTopPlace;
  if PlaceBefore(Limit, Place) then
    Place := Limit;
  if (Place.Line = FTop.Line) and (Place.Row = FTop.Row) then
    Exit;
  FTop := Place;
  FScrollBar.Position := RowIndexOf(FTop);
  Invalidate;
end;

procedure TTextView.Layout;
var
  Width: LongInt;
begin
  Width := Scaled(Theme.ScrollBarWidth);
  FScrollBar.AssignBounds(Unscaled(RectangleWidth(PixelBounds) - 2 - Width), Unscaled(2), Unscaled(Width),
    Unscaled(RectangleHeight(PixelBounds) - 4));
  UpdateScrollBar;
  inherited Layout;
end;

procedure TTextView.UpdateScrollBar;
var
  Total: LongInt;
  Needed: Boolean;
begin
  { The top may have gone past the end (lines removed, rows unwrapped). }
  SetTop(FTop);
  Total := TotalRows;
  Needed := Total > VisibleRows;
  FScrollBar.SetRange(0, Total, VisibleRows);
  FScrollBar.Position := RowIndexOf(FTop);
  if FScrollBar.Visible <> Needed then
    FScrollBar.Visible := Needed;
end;

procedure TTextView.ReceiveMessage(var Message: TPostedMessage);
begin
  if (Message.Code = MessageNotify) and (TControl(Message.Parameter1) = FScrollBar) then
  begin
    if (Message.Parameter2 = NotifyChanged) and (FScrollBar.Position <> RowIndexOf(FTop)) then
    begin
      FTop := PlaceOfRowIndex(FScrollBar.Position);
      Invalidate;
    end;
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

procedure TTextView.ScrollToCaret;
var
  Place: TRowPlace;
  Bottom: TRowPlace;
  X: LongInt;
  Room: LongInt;
begin
  Place := PlaceOfCaret;
  Bottom := StepRows(FTop, VisibleRows - 1);
  if PlaceBefore(Place, FTop) then
    SetTop(Place)
  else if PlaceBefore(Bottom, Place) then
    SetTop(StepRows(Place, -(VisibleRows - 1)));
  if FWordWrap then
  begin
    FScrollX := 0;
    Exit;
  end;
  Room := RectangleWidth(PixelBounds) - 2 * TextLeft;
  if FScrollBar.Visible then
    Room := Room - RectangleWidth(FScrollBar.PixelBounds);
  X := XInRow(LayoutOf(FCaret.Line), 0, FCaret.Column);
  if X < FScrollX then
    FScrollX := X
  else if X > FScrollX + Room then
    FScrollX := X - Room;
  if FScrollX < 0 then
    FScrollX := 0;
end;

procedure TTextView.Wheel(Steps: LongInt);
begin
  SetTop(StepRows(FTop, -Steps * WheelRows));
end;

{ --- The caret and the selection --------------------------------------------------------- }

procedure TTextView.UserMovedCaret;
begin
end;

function TTextView.ShowsAsField: Boolean;
begin
  Result := Enabled;
end;

procedure TTextView.ReportCaret;
begin
  if SamePosition(FCaret, FReportedCaret) then
    Exit;
  FReportedCaret := FCaret;
  if Assigned(FOnCaretMoved) then
    FOnCaretMoved(Self);
end;

procedure TTextView.MoveCaret(Line, Column: LongInt; Extend: Boolean);
begin
  if Line < 0 then
    Line := 0;
  if Line >= FLines.Count then
    Line := FLines.Count - 1;
  if Column < 0 then
    Column := 0;
  if Column > LineLength(Line) then
    Column := LineLength(Line);
  FCaret := MakePosition(Line, Column);
  if not Extend then
    FAnchor := FCaret;
  UserMovedCaret;
  ScrollToCaret;
  Invalidate;
  ReportCaret;
end;

procedure TTextView.MoveCaretByRows(Count: LongInt; Extend: Boolean);
var
  Place: TRowPlace;
  Target: TRowPlace;
begin
  Place := PlaceOfCaret;
  if FDesiredX < 0 then
    FDesiredX := XInRow(LayoutOf(FCaret.Line), Place.Row, FCaret.Column);
  Target := StepRows(Place, Count);
  MoveCaret(Target.Line, ColumnNearestX(LayoutOf(Target.Line), Target.Row, FDesiredX), Extend);
end;

procedure TTextView.MoveCaretToRowStart(Extend: Boolean);
var
  Place: TRowPlace;
begin
  Place := PlaceOfCaret;
  MoveCaret(FCaret.Line, LayoutOf(FCaret.Line).Rows[Place.Row], Extend);
end;

procedure TTextView.MoveCaretToRowEnd(Extend: Boolean);
var
  Place: TRowPlace;
begin
  Place := PlaceOfCaret;
  MoveCaret(FCaret.Line, RowCaretLimit(LayoutOf(FCaret.Line), Place.Row), Extend);
end;

function TTextView.PositionAt(X, Y: LongInt): TTextPosition;
var
  RowsDown: LongInt;
  Place: TRowPlace;
begin
  if Y < 2 then
    RowsDown := -1
  else
    RowsDown := (Y - 2) div LineHeight;
  Place := StepRows(FTop, RowsDown);
  Result := MakePosition(Place.Line, ColumnNearestX(LayoutOf(Place.Line), Place.Row, X - TextLeft + FScrollX));
end;

function TTextView.SelectionStart: TTextPosition;
begin
  if PositionBefore(FAnchor, FCaret) then
    Result := FAnchor
  else
    Result := FCaret;
end;

function TTextView.SelectionEnd: TTextPosition;
begin
  if PositionBefore(FAnchor, FCaret) then
    Result := FCaret
  else
    Result := FAnchor;
end;

function TTextView.HasSelection: Boolean;
begin
  Result := not SamePosition(FAnchor, FCaret);
end;

procedure TTextView.SelectRange(const Start, Finish: TTextPosition);
begin
  MoveCaret(Start.Line, Start.Column, False);
  MoveCaret(Finish.Line, Finish.Column, True);
end;

procedure TTextView.SelectAll;
var
  LastLine: LongInt;
begin
  LastLine := FLines.Count - 1;
  SelectRange(MakePosition(0, 0), MakePosition(LastLine, LineLength(LastLine)));
end;

function TTextView.SelectedText: string;
begin
  Result := TextBetween(SelectionStart, SelectionEnd);
end;

function TTextView.TextBetween(Start, Finish: TTextPosition): string;
var
  Swapped: TTextPosition;
  First: string;
  Last: string;
  Size: LongInt;
  Line: LongInt;
  Place: LongInt;

  procedure Append(const Piece: string);
  begin
    if Piece <> '' then
      Move(Piece[1], Result[Place], Length(Piece));
    Place := Place + Length(Piece);
  end;

begin
  if PositionBefore(Finish, Start) then
  begin
    Swapped := Start;
    Start := Finish;
    Finish := Swapped;
  end;
  if Start.Line = Finish.Line then
    Exit(CharacterRange(FLines[Start.Line], Start.Column, Finish.Column - Start.Column));
  First := Copy(FLines[Start.Line], ByteOfColumn(FLines[Start.Line], Start.Column) + 1, MaxInt);
  Last := Copy(FLines[Finish.Line], 1, ByteOfColumn(FLines[Finish.Line], Finish.Column));
  { Measured first and copied once: the text may be large. }
  Size := Length(First) + Length(Last) + (Finish.Line - Start.Line);
  for Line := Start.Line + 1 to Finish.Line - 1 do
    Size := Size + Length(FLines[Line]);
  Result := '';
  SetLength(Result, Size);
  Place := 1;
  Append(First);
  for Line := Start.Line + 1 to Finish.Line - 1 do
  begin
    Append(#10);
    Append(FLines[Line]);
  end;
  Append(#10);
  Append(Last);
end;

function TTextView.AllText: string;
var
  LastLine: LongInt;
begin
  LastLine := FLines.Count - 1;
  Result := TextBetween(MakePosition(0, 0), MakePosition(LastLine, LineLength(LastLine)));
end;

procedure TTextView.SetAllText(const Value: string);
var
  Start: LongInt;
  Index: LongInt;
  Breaks: LongInt;
begin
  FChanging := True;
  FLines.Clear;
  Breaks := 0;
  for Index := 1 to Length(Value) do
    if Value[Index] = #10 then
      Inc(Breaks);
  FLines.Capacity := Breaks + 1;
  Start := 1;
  for Index := 1 to Length(Value) do
    if Value[Index] = #10 then
    begin
      FLines.Add(Copy(Value, Start, Index - Start));
      Start := Index + 1;
    end;
  FLines.Add(Copy(Value, Start, Length(Value) - Start + 1));
  FChanging := False;
  FCaret := MakePosition(0, 0);
  FAnchor := FCaret;
  FTop := MakeRowPlace(0, 0);
  FScrollX := 0;
  LinesChanged(nil);
  ReportCaret;
end;

procedure TTextView.GoToLine(Line: LongInt);
begin
  MoveCaret(Line, 0, False);
end;

function TTextView.FindText(const Pattern: string; const Options: TSearchOptions): Boolean;
var
  From: TTextPosition;
  MatchStart: TTextPosition;
  MatchEnd: TTextPosition;
begin
  if Options.Direction = SearchDown then
    From := SelectionEnd
  else
    From := SelectionStart;
  Result := FindInLines(FLines, Pattern, From, Options, MatchStart, MatchEnd);
  if Result then
    SelectRange(MatchStart, MatchEnd);
end;

procedure TTextView.SetFont(Family: TFontFamily; PointTenths: LongWord; Bold: Boolean);
begin
  FFontFamily := Family;
  FFontPointTenths := PointTenths;
  FFontBold := Bold;
  Inc(FGeneration);
  FDesiredX := -1;
  UpdateScrollBar;
  ScrollToCaret;
  Invalidate;
end;

procedure TTextView.SetWordWrap(Value: Boolean);
begin
  if FWordWrap = Value then
    Exit;
  FWordWrap := Value;
  FScrollX := 0;
  FTop.Row := 0;
  Inc(FGeneration);
  FDesiredX := -1;
  ForgetRows;
  UpdateScrollBar;
  ScrollToCaret;
  Invalidate;
end;

{ --- Changing the text ---------------------------------------------------------------- }

procedure TTextView.LinesChanged(Sender: TObject);
begin
  if FChanging then
    Exit;
  { Someone changed Lines: nothing remembered about them holds. }
  if FLines.Count = 0 then
  begin
    FChanging := True;
    FLines.Add('');
    FChanging := False;
  end;
  if FCaret.Line >= FLines.Count then
    FCaret := MakePosition(FLines.Count - 1, 0);
  if FAnchor.Line >= FLines.Count then
    FAnchor := FCaret;
  Inc(FGeneration);
  ForgetRows;
  UpdateScrollBar;
  Invalidate;
end;

{ Inserted cut at its line feeds. }
procedure SplitAtLineFeeds(const Inserted: string; Pieces: TStringList);
var
  Start: LongInt;
  Index: LongInt;
begin
  Start := 1;
  for Index := 1 to Length(Inserted) do
    if Inserted[Index] = #10 then
    begin
      Pieces.Add(Copy(Inserted, Start, Index - Start));
      Start := Index + 1;
    end;
  Pieces.Add(Copy(Inserted, Start, Length(Inserted) - Start + 1));
end;

function TTextView.ReplaceLines(const Start, Finish: TTextPosition; const Inserted: string): TTextPosition;
var
  Pieces: TStringList;
  Before: string;
  After: string;
  OldCount: LongInt;
  NewCount: LongInt;
  Index: LongInt;
  Rebuilt: TStringList;
  OldRows: array of LongInt;
  Shared: LongInt;
begin
  Pieces := TStringList.Create;
  try
    SplitAtLineFeeds(Inserted, Pieces);
    Before := Copy(FLines[Start.Line], 1, ByteOfColumn(FLines[Start.Line], Start.Column));
    After := Copy(FLines[Finish.Line], ByteOfColumn(FLines[Finish.Line], Finish.Column) + 1, MaxInt);
    OldCount := Finish.Line - Start.Line + 1;
    NewCount := Pieces.Count;
    if NewCount = 1 then
      Result := MakePosition(Start.Line, Start.Column + CountCharacters(Pieces[0]))
    else
      Result := MakePosition(Start.Line + NewCount - 1, CountCharacters(Pieces[NewCount - 1]));
    Pieces[0] := Before + Pieces[0];
    Pieces[NewCount - 1] := Pieces[NewCount - 1] + After;
    FChanging := True;
    if Abs(NewCount - OldCount) > RebuildThreshold then
    begin
      { Many lines in or out: a list built afresh, not shifted line by
        line. }
      Rebuilt := TStringList.Create;
      try
        Rebuilt.Capacity := FLines.Count - OldCount + NewCount;
        for Index := 0 to Start.Line - 1 do
          Rebuilt.Add(FLines[Index]);
        Rebuilt.AddStrings(Pieces);
        for Index := Finish.Line + 1 to FLines.Count - 1 do
          Rebuilt.Add(FLines[Index]);
        FLines.Assign(Rebuilt);
      finally
        Rebuilt.Free;
      end;
    end
    else
    begin
      Shared := OldCount;
      if NewCount < Shared then
        Shared := NewCount;
      for Index := 0 to Shared - 1 do
        FLines[Start.Line + Index] := Pieces[Index];
      for Index := Shared to NewCount - 1 do
        FLines.Insert(Start.Line + Index, Pieces[Index]);
      for Index := OldCount - 1 downto Shared do
        FLines.Delete(Start.Line + Index);
    end;
    FChanging := False;
  finally
    Pieces.Free;
  end;
  Inc(FGeneration);
  { The rows of the lines replaced are laid out again when wanted; the
    others are still right. }
  if Length(FRowCounts) = FLines.Count - NewCount + OldCount then
  begin
    if NewCount = OldCount then
    begin
      for Index := 0 to NewCount - 1 do
        FRowCounts[Start.Line + Index] := -1;
    end
    else
    begin
      OldRows := Copy(FRowCounts, 0, Length(FRowCounts));
      SetLength(FRowCounts, FLines.Count);
      for Index := 0 to NewCount - 1 do
        FRowCounts[Start.Line + Index] := -1;
      for Index := Start.Line + OldCount to High(OldRows) do
        FRowCounts[Index - OldCount + NewCount] := OldRows[Index];
    end;
  end;
end;

{ --- Painting -------------------------------------------------------------------------------- }

procedure TTextView.PaintRow(var Canvas: TCanvas; Face: PFontFace; Line: LongInt; const LineLayout: TLineLayout;
  Row, Top: LongInt);
var
  RowLeft: LongInt;
  First: LongInt;
  Last: LongInt;
  Room: LongInt;
  SelectionFirst: TTextPosition;
  SelectionLast: TTextPosition;
  FromColumn: LongInt;
  ToColumn: LongInt;
  Left: LongInt;
  Width: LongInt;
begin
  RowLeft := TextLeft - FScrollX;
  { Only what can show (a long line is mostly off to the side). }
  Room := RectangleWidth(PixelBounds);
  First := ColumnAtX(LineLayout, Row, FScrollX - TextLeft);
  Last := ColumnAtX(LineLayout, Row, FScrollX + Room) + 1;
  if Last > RowEnd(LineLayout, Row) then
    Last := RowEnd(LineLayout, Row);
  DrawLayoutRange(Canvas, Face, FLines[Line], LineLayout, Row, First, Last, RowLeft, Top, Theme.FieldText);
  if not (Focused and HasSelection) then
    Exit;
  SelectionFirst := SelectionStart;
  SelectionLast := SelectionEnd;
  if (Line < SelectionFirst.Line) or (Line > SelectionLast.Line) then
    Exit;
  FromColumn := LineLayout.Rows[Row];
  ToColumn := RowEnd(LineLayout, Row);
  if (Line = SelectionFirst.Line) and (SelectionFirst.Column > FromColumn) then
    FromColumn := SelectionFirst.Column;
  if (Line = SelectionLast.Line) and (SelectionLast.Column < ToColumn) then
    ToColumn := SelectionLast.Column;
  if ToColumn < FromColumn then
    Exit;
  Left := RowLeft + XInRow(LineLayout, Row, FromColumn);
  Width := XInRow(LineLayout, Row, ToColumn) - XInRow(LineLayout, Row, FromColumn);
  { A line break selected shows as a little space after the last row. }
  if (Line < SelectionLast.Line) and (Row = RowCountOfLayout(LineLayout) - 1) then
    Width := Width + Scaled(LineBreakWidth);
  if Width <= 0 then
    Exit;
  FillRectangle(Canvas, MakeRectangle(Left, Top, Width, LineHeight), Theme.Selection);
  DrawLayoutRange(Canvas, Face, FLines[Line], LineLayout, Row, FromColumn, ToColumn, RowLeft, Top,
    Theme.SelectionText);
end;

procedure TTextView.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Inner: TCanvas;
  Face: PFontFace;
  Right: LongInt;
  Place: TRowPlace;
  Caret: TRowPlace;
  LineLayout: TLineLayout;
  Top: LongInt;
  Height: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if ShowsAsField then
    FillRectangle(Canvas, Box, Theme.Field)
  else
    FillRectangle(Canvas, Box, Theme.Face);
  DrawBevel(Canvas, Box, SunkenThemeBevel);
  Face := EditFace;
  if Face = nil then
    Exit;
  Right := RectangleWidth(Box) - 2;
  if FScrollBar.Visible then
    Right := Right - RectangleWidth(FScrollBar.PixelBounds);
  Inner := Canvas;
  NarrowCanvasClip(Inner, MakeRectangle(2, 2, Right - 2, RectangleHeight(Box) - 4));
  Caret := PlaceOfCaret;
  Height := LineHeight;
  Place := FTop;
  Top := 2;
  while (Place.Line < FLines.Count) and (Top < RectangleHeight(Box)) do
  begin
    LineLayout := LayoutOf(Place.Line);
    while (Place.Row < RowCountOfLayout(LineLayout)) and (Top < RectangleHeight(Box)) do
    begin
      PaintRow(Inner, Face, Place.Line, LineLayout, Place.Row, Top);
      if Focused and (Place.Line = Caret.Line) and (Place.Row = Caret.Row) then
        FillRectangle(Inner, MakeRectangle(TextLeft - FScrollX + XInRow(LineLayout, Place.Row, FCaret.Column), Top,
          Scaled(1), Height), Theme.FieldText);
      Top := Top + Height;
      Inc(Place.Row);
    end;
    Place := MakeRowPlace(Place.Line + 1, 0);
  end;
end;

end.

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
  The user's text selection over a laid out page, without the control
  around it (TWebView uses it; host tests drive it the same way): the
  text index of the painted runs (WebView.TextIndex), the selection's
  anchor and focus in it, kept as the document's Selection
  (WebView.SelectionMapping) both ways.

  The index points at the layout's text boxes. Those are freed when the
  layout is brought up to date (a page's handler that reads a size, a
  frame, an animation), so the index is only ever read while it was
  built from the display list of the layout as it is now: every entry
  point checks that (IndexCurrent) and builds it again otherwise, and a
  place in the text (TTextPosition) from an older index is not used -
  the selection is found again from the document's, which the DOM kept
  up to date (its live range).
}
unit WebView.PageSelection;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom,
  Web.Layout.Document,
  Web.Paint.Painter,
  WebView.TextGroups,
  WebView.TextIndex;

type
  TPageSelection = class
  private
    FIndex: TPageTextIndex;
    FDocument: TDocument;
    FLayout: TDocumentLayout;
    FPainter: TDocumentPainter;
    FIndexVersion: LongWord;
    FIndexValid: Boolean;
    { The index the anchor and focus were taken from. }
    FIndexGeneration: LongWord;
    FAnchor, FFocus: TTextPosition;
    FFromDocument: Boolean;
    FSettingDocument: Boolean;
    procedure Push;
    procedure Pull;
    procedure Forget;
  public
    constructor Create;
    destructor Destroy; override;
    { The document, its layout and painter (nil: none); the selection
      starts empty. The layout must outlive the attachment. }
    procedure Attach(Document: TDocument; Layout: TDocumentLayout; Painter: TDocumentPainter);
    { The index was built from the layout's display list as it is now. }
    function IndexCurrent: Boolean;
    { Brings the index up to the painter's display list (building it if
      the layout changed) and takes the document's selection if it
      changed. The caller lays out first if it wants the newest text. }
    procedure Refresh;
    { The document's selection changed (its observer): the painted
      selection is taken from it when next used. False when the change
      was this selection's own. }
    function DocumentSelectionChanged: Boolean;
    { The nearest place in the text to a document point (CSS px). }
    function PositionAt(X, Y: Single; constref View: TTextViewport): TTextPosition;
    { Selects from Anchor to Focus (places in the current index: from
      PositionAt or the index since); True when it changed. Places from
      an index that is gone are ignored. }
    function Select(constref Anchor, Focus: TTextPosition): Boolean;
    { Moves the focus, the anchor staying (a drag). }
    function Extend(constref Focus: TTextPosition): Boolean;
    function Clear: Boolean;
    function SelectAll: Boolean;
    { The word (double click) or the line (triple click) at a place. }
    function SelectWordAt(constref Position: TTextPosition): Boolean;
    function SelectLineAt(constref Position: TTextPosition): Boolean;
    function HasSelection: Boolean;
    function SelectedText: string;
    { Where the selection is shown (document CSS px; viewport px for
      fixed text). }
    function Rectangles(constref View: TTextViewport): TTextRectangleArray;
    property Index: TPageTextIndex read FIndex;
    property Anchor: TTextPosition read FAnchor;
    property Focus: TTextPosition read FFocus;
    { Bumped whenever the index is built again. }
    property IndexGeneration: LongWord read FIndexGeneration;
  end;

{ The viewport of a layout for the index (its scroll offset and size). }
function ViewportOfLayout(Layout: TDocumentLayout): TTextViewport;

implementation

uses
  SysUtils,
  Web.Dom.Exceptions,
  WebView.SelectionMapping;

function ViewportOfLayout(Layout: TDocumentLayout): TTextViewport;
begin
  Result := Default(TTextViewport);
  if Layout = nil then
    Exit;
  Layout.GetScrollOffset(nil, Result.ScrollX, Result.ScrollY);
  Result.Width := Layout.ViewportWidth;
  Result.Height := Layout.ViewportHeight;
end;

function ValidPosition(Index: TPageTextIndex; constref Position: TTextPosition): Boolean;
begin
  Result := (Position.Run >= 0) and (Position.Run < Index.Count) and (Position.Offset >= 0) and
    (Position.Offset <= Index.Run(Position.Run)^.TextLength);
end;

constructor TPageSelection.Create;
begin
  inherited Create;
  FIndex := TPageTextIndex.Create;
  FAnchor := TextPosition(-1, 0);
  FFocus := FAnchor;
end;

destructor TPageSelection.Destroy;
begin
  FIndex.Free;
  inherited Destroy;
end;

procedure TPageSelection.Forget;
begin
  FAnchor := TextPosition(-1, 0);
  FFocus := FAnchor;
end;

procedure TPageSelection.Attach(Document: TDocument; Layout: TDocumentLayout; Painter: TDocumentPainter);
begin
  FDocument := Document;
  FLayout := Layout;
  FPainter := Painter;
  FIndex.Clear;
  FIndexValid := False;
  Inc(FIndexGeneration);
  FFromDocument := False;
  Forget;
end;

function TPageSelection.IndexCurrent: Boolean;
begin
  Result := FIndexValid and (FPainter <> nil) and (FLayout <> nil) and (FPainter.BuiltVersion = FIndexVersion) and
    (FLayout.DisplayListVersion = FIndexVersion);
end;

procedure TPageSelection.Refresh;
begin
  if (FPainter = nil) or (FLayout = nil) then
  begin
    FIndex.Clear;
    FIndexValid := False;
    Forget;
    Exit;
  end;
  FPainter.Refresh;
  if not IndexCurrent then
  begin
    FIndex.Build(FPainter.DisplayList);
    FIndexVersion := FPainter.BuiltVersion;
    FIndexValid := True;
    Inc(FIndexGeneration);
    { The runs changed: the places in the old ones mean nothing now; the
      selection is found again from the document's. }
    Forget;
    FFromDocument := True;
  end;
  Pull;
end;

function TPageSelection.DocumentSelectionChanged: Boolean;
begin
  Result := not FSettingDocument;
  if Result then
    FFromDocument := True;
end;

procedure TPageSelection.Push;
var
  AnchorNode, FocusNode: TNode;
  AnchorOffset, FocusOffset: Integer;
begin
  FFromDocument := False;
  if FDocument = nil then
    Exit;
  FSettingDocument := True;
  try
    try
      if ValidPosition(FIndex, FAnchor) and ValidPosition(FIndex, FFocus) and
        TextPositionToDomPoint(FIndex, FAnchor, AnchorNode, AnchorOffset) and
        TextPositionToDomPoint(FIndex, FFocus, FocusNode, FocusOffset) and
        (AnchorNode.NodeDocument = FDocument) and (FocusNode.NodeDocument = FDocument) and
        AnchorNode.IsConnected and FocusNode.IsConnected then
        FDocument.Selection.SetBaseAndExtent(AnchorNode, AnchorOffset, FocusNode, FocusOffset)
      else
        FDocument.Selection.RemoveAllRanges;
    except
      on EDomException do
        FDocument.Selection.RemoveAllRanges;
    end;
  finally
    FSettingDocument := False;
  end;
end;

procedure TPageSelection.Pull;
var
  Selection: TDocumentSelection;
begin
  if not FFromDocument or (FDocument = nil) or not IndexCurrent then
    Exit;
  FFromDocument := False;
  Selection := FDocument.Selection;
  if (Selection.Range = nil) or (Selection.AnchorNode = nil) or (Selection.FocusNode = nil) then
  begin
    Forget;
    Exit;
  end;
  FAnchor := DomPointToTextPosition(FIndex, Selection.AnchorNode, Selection.AnchorOffset);
  FFocus := DomPointToTextPosition(FIndex, Selection.FocusNode, Selection.FocusOffset);
  if (FAnchor.Run < 0) or (FFocus.Run < 0) then
    Forget;
end;

function TPageSelection.PositionAt(X, Y: Single; constref View: TTextViewport): TTextPosition;
begin
  Refresh;
  Result := FIndex.PositionAt(X, Y, View);
end;

function TPageSelection.Select(constref Anchor, Focus: TTextPosition): Boolean;
var
  NewAnchor, NewFocus: TTextPosition;
begin
  Result := False;
  { Copies: the arguments may be this selection's own fields. }
  NewAnchor := Anchor;
  NewFocus := Focus;
  if not IndexCurrent then
    Exit;
  if (NewAnchor.Run >= 0) and (not ValidPosition(FIndex, NewAnchor) or not ValidPosition(FIndex, NewFocus)) then
    Exit;
  if (NewAnchor.Run < 0) or (NewFocus.Run < 0) then
  begin
    NewAnchor := TextPosition(-1, 0);
    NewFocus := NewAnchor;
  end;
  if (NewAnchor.Run = FAnchor.Run) and (NewAnchor.Offset = FAnchor.Offset) and (NewFocus.Run = FFocus.Run) and
     (NewFocus.Offset = FFocus.Offset) and not FFromDocument then
    Exit;
  FAnchor := NewAnchor;
  FFocus := NewFocus;
  Push;
  Result := True;
end;

function TPageSelection.Extend(constref Focus: TTextPosition): Boolean;
var
  Kept: TTextPosition;
begin
  Kept := FAnchor;
  if Kept.Run < 0 then
    Kept := Focus;
  Result := Select(Kept, Focus);
end;

function TPageSelection.Clear: Boolean;
begin
  Result := False;
  if (FAnchor.Run < 0) and not FFromDocument and ((FDocument = nil) or (FDocument.Selection.Range = nil)) then
    Exit;
  Forget;
  FFromDocument := False;
  Push;
  Result := True;
end;

function TPageSelection.SelectAll: Boolean;
begin
  Refresh;
  Result := Select(FIndex.FirstPosition, FIndex.LastPosition);
end;

function TPageSelection.SelectWordAt(constref Position: TTextPosition): Boolean;
var
  WordStart, WordEnd: TTextPosition;
begin
  Result := False;
  if not IndexCurrent or not ValidPosition(FIndex, Position) then
    Exit;
  FIndex.WordAround(Position, WordStart, WordEnd);
  Result := Select(WordStart, WordEnd);
end;

function TPageSelection.SelectLineAt(constref Position: TTextPosition): Boolean;
var
  LineStart, LineEnd: TTextPosition;
begin
  Result := False;
  if not IndexCurrent or not ValidPosition(FIndex, Position) then
    Exit;
  FIndex.LineAround(Position, LineStart, LineEnd);
  Result := Select(LineStart, LineEnd);
end;

function TPageSelection.HasSelection: Boolean;
begin
  if FFromDocument or not IndexCurrent then
    Refresh;
  Result := IndexCurrent and ValidPosition(FIndex, FAnchor) and ValidPosition(FIndex, FFocus) and
    (TPageTextIndex.Compare(FAnchor, FFocus) <> 0);
end;

function TPageSelection.SelectedText: string;
begin
  Result := '';
  if HasSelection then
    Result := FIndex.TextBetween(FAnchor, FFocus);
end;

function TPageSelection.Rectangles(constref View: TTextViewport): TTextRectangleArray;
begin
  Result := nil;
  if HasSelection then
    Result := FIndex.RangeRectangles(FAnchor, FFocus, View);
end;

end.

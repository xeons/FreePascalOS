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
  Places in the painted text (WebView.TextIndex: a run and a byte of its
  rendered text) against DOM boundary points (a node and an offset), so
  the user's selection is the document's (script sees it through
  getSelection) and a selection script makes is painted.

  A run's text box knows its text node and the node's data when its
  rendered text was made; Web.Layout.TextOffsets maps offsets across
  collapsed white space. A point in an element (between children) is
  shown at the first painted text at or after it in tree order.
}
unit WebView.SelectionMapping;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom,
  WebView.TextIndex;

{ The DOM point for a place in the text; False for text no node has
  (generated content without an element). }
function TextPositionToDomPoint(Index: TPageTextIndex; constref Position: TTextPosition; out Node: TNode;
  out Offset: Integer): Boolean;
{ The place in the text for a DOM point; Run -1 when nothing painted is
  at or after it. }
function DomPointToTextPosition(Index: TPageTextIndex; Node: TNode; Offset: Integer): TTextPosition;

implementation

uses
  Web.Layout.Boxes,
  Web.Layout.TextOffsets;

function TextPositionToDomPoint(Index: TPageTextIndex; constref Position: TTextPosition; out Node: TNode;
  out Offset: Integer): Boolean;
var
  Entry: PTextRunEntry;
  Box: TTextBox;
begin
  Node := nil;
  Offset := 0;
  Result := False;
  if (Position.Run < 0) or (Position.Run >= Index.Count) then
    Exit;
  Entry := Index.Run(Position.Run);
  Box := Entry^.Box;
  if (Box = nil) or (Box.Node = nil) then
    Exit;
  if Box.IsGenerated or not Box.Node.IsText then
  begin
    { ::before, ::after or a marker: the start of its element. }
    Node := Box.Node;
    if Node.IsText then
      Node := Node.ParentNode;
    Result := Node <> nil;
    Exit;
  end;
  Node := Box.Node;
  Offset := RenderedToSourceOffset(Box.SourceText, Box.Text, Entry^.TextStart - 1 + Position.Offset);
  if Offset > NodeLength(Node) then
    Offset := NodeLength(Node);
  Result := True;
end;

{ The first node at or after the point in tree order. }
function NodeAtPoint(Node: TNode; Offset: Integer): TNode;
begin
  Result := nil;
  if Node.IsContainer then
    Result := Node.ChildAt(Offset);
  if Result = nil then
    Result := Node.NextInTreeSkippingChildren;
end;

function DomPointToTextPosition(Index: TPageTextIndex; Node: TNode; Offset: Integer): TTextPosition;
var
  Walk, Rendered, RunStart, Best: Integer;
  Entry: PTextRunEntry;
  Target, Candidate, BestNode: TNode;
begin
  Result := TextPosition(-1, 0);
  if Node = nil then
    Exit;
  if Node.IsText then
  begin
    Best := -1;
    for Walk := 0 to Index.Count - 1 do
    begin
      Entry := Index.Run(Walk);
      if (Entry^.Box = nil) or (Entry^.Box.Node <> Node) or Entry^.Box.IsGenerated then
        Continue;
      Rendered := SourceToRenderedOffset(Entry^.Box.SourceText, Entry^.Box.Text, Offset);
      RunStart := Entry^.TextStart - 1;
      if (Rendered >= RunStart) and (Rendered <= RunStart + Entry^.TextLength) then
        Exit(TextPosition(Walk, Rendered - RunStart));
      { Between this node's runs (a space dropped at a line end). }
      if (Rendered > RunStart + Entry^.TextLength) then
        Result := TextPosition(Walk, Entry^.TextLength)
      else if (Best < 0) and (Result.Run < 0) then
        Best := Walk;
    end;
    if Result.Run >= 0 then
      Exit;
    if Best >= 0 then
      Exit(TextPosition(Best, 0));
    { Not painted: look after it. }
    Target := Node.NextInTreeSkippingChildren;
  end
  else
    Target := NodeAtPoint(Node, Offset);
  if Target = nil then
  begin
    if Index.Count > 0 then
      Result := Index.LastPosition;
    Exit;
  end;
  BestNode := nil;
  for Walk := 0 to Index.Count - 1 do
  begin
    Entry := Index.Run(Walk);
    if (Entry^.Box = nil) or (Entry^.Box.Node = nil) then
      Continue;
    Candidate := Entry^.Box.Node;
    if (Candidate <> Target) and not Target.IsInclusiveAncestorOf(Candidate) and
      ((Target.CompareDocumentPosition(Candidate) and DocumentPositionFollowing) = 0) then
      Continue;
    if (BestNode = nil) or ((Candidate <> BestNode) and
      ((Candidate.CompareDocumentPosition(BestNode) and DocumentPositionFollowing) <> 0)) then
    begin
      BestNode := Candidate;
      Result := TextPosition(Walk, 0);
    end;
  end;
  if (Result.Run < 0) and (Index.Count > 0) then
    Result := Index.LastPosition;
end;

end.

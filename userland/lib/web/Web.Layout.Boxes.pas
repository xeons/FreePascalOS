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
  The box tree.

  Boxes are made from the DOM and the computed styles
  (Web.Layout.TreeBuilder): one per element that generates a box, one
  per text node with something to show (not one per word or line), one
  per ::before, ::after and ::marker, and anonymous ones where CSS needs
  them (block boxes around runs of inline content beside blocks, the
  viewport). A box knows its node (nil when anonymous), its style (a
  reference), its kind and its tree links.

  Geometry is in CSS pixels, as singles: a box's border box position is
  relative to the border box of its nearest ancestor that is not an
  inline box (inline boxes are drawn from line fragments and have no
  position of their own), so moving a subtree moves one number. The
  used margins, borders and padding are kept for painting and hit
  testing.

  A block container whose children are inline keeps its lines as two
  compact arrays (TInlineContent): line boxes, and fragments (a piece
  of text of one text box, an atomic inline, or the part of an inline
  box on one line). Text is not copied into fragments: a fragment is a
  byte range of its text box's text.
}
unit Web.Layout.Boxes;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom, Css.ComputedStyle, Image.Model, Web.Text.FontInstances;

type
  TBoxKind = (
    { A block container (block, list-item, flow-root, inline-block's
      inside, table cells and captions). }
    bkBlock,
    { A non-atomic inline box (span, a, em ...). }
    bkInline,
    bkText,
    { <br>. }
    bkLineBreak,
    { An element whose content is outside CSS (img, video, canvas ...). }
    bkReplaced,
    bkFlex,
    bkGrid,
    bkTable,
    bkTableRowGroup,
    bkTableRow,
    bkTableCell,
    bkTableColumn,
    bkTableColumnGroup,
    bkTableCaption,
    { The initial containing block, root of the tree. }
    bkViewport);

  TBoxFlag = (
    bfAnonymous,
    { Its outer display is inline (an atomic inline unless bkInline). }
    bfInlineLevel,
    bfFloatLeft,
    bfFloatRight,
    { position: absolute or fixed. }
    bfAbsolute,
    bfFixed,
    { position: relative or sticky. }
    bfRelative,
    bfSticky,
    { It establishes a block formatting context. }
    bfNewFormattingContext,
    { Its children are inline-level (it has an inline formatting context). }
    bfChildrenInline,
    bfNeedsLayout,
    bfChildNeedsLayout,
    bfStackingContext,
    bfClipsOverflow,
    bfScrollContainer,
    bfBefore,
    bfAfter,
    bfMarker,
    bfOutsideMarker,
    bfListItem,
    bfRootElement,
    { A block-level box inside an inline formatting context. }
    bfBlockInInline,
    { Its layout used floats from outside it. }
    bfSawOutsideFloats,
    { Absolutely positioned boxes below it have a containing block
      above it (so its layout cannot be skipped). }
    bfHasEscapingAbsolute,
    { Its layout placed floats in a formatting context outside it: a
      skipped layout would leave them out of that context, and the boxes
      after it would not flow around them. }
    bfHasEscapingFloats);
  TBoxFlags = set of TBoxFlag;

  TBoxSide = (sideTop, sideRight, sideBottom, sideLeft);
  TBoxEdges = array[TBoxSide] of Single;

  TFragmentKind = (fkText, fkAtomic, fkInlineBox, fkLineBreak);

  TLineFragment = record
    Box: TObject;
    Kind: TFragmentKind;
    { fkInlineBox: whether its start (left) and end (right) edges are on
      this line. }
    HasStart, HasEnd: Boolean;
    { Bytes of the text box's text. }
    TextStart, TextLength: Integer;
    { The fragment's box relative to the container's border box: for
      text the font's ascent to descent; for an inline box its border
      box; for an atomic inline its margin box. }
    X, Y, Width, Height: Single;
    { The baseline, relative to the container's border box. }
    Baseline: Single;
    { Extra space added after each space (text-align: justify,
      word-spacing) and after each character (letter-spacing). }
    SpaceExtra: Single;
    LetterExtra: Single;
    { Hidden behind a line's ellipsis (text-overflow): not painted. }
    Clipped: Boolean;
  end;
  PLineFragment = ^TLineFragment;

  TLineBoxRecord = record
    Top, Height, Baseline: Single;
    FirstFragment, FragmentCount: Integer;
  end;

  { An ellipsis drawn at the end of a line (text-overflow, line clamping):
    where its pen starts and its baseline, relative to the container's
    border box, in the container's font and colour. }
  TLineEllipsis = record
    X, Baseline: Single;
  end;

  TInlineContent = class
  public
    Lines: array of TLineBoxRecord;
    LineCount: Integer;
    Fragments: array of TLineFragment;
    FragmentCount: Integer;
    Ellipses: array of TLineEllipsis;
    EllipsisCount: Integer;
    { The inline items (Web.Layout.InlineItems), owned; ItemsValid until
      the content changes. }
    Items: TObject;
    ItemsValid: Boolean;
    destructor Destroy; override;
    procedure Clear;
    function AddFragment: PLineFragment;
    procedure AddLine(const Line: TLineBoxRecord);
  end;

  TLayoutBox = class
  public
    Node: TNode;
    Style: TCssComputedStyle;
    Kind: TBoxKind;
    Flags: TBoxFlags;
    Parent, FirstChild, LastChild, PreviousSibling, NextSibling: TLayoutBox;
    { The next box made for the same node (pseudo-element boxes, the
      marker), for detaching them when the node goes. }
    NextForNode: TLayoutBox;
    X, Y, Width, Height: Single;
    Margin, Border, Padding: TBoxEdges;
    { position: relative's offset (painting and hit testing add it). }
    RelativeX, RelativeY: Single;
    { Where an absolutely positioned box would have been (relative to
      its layout parent's border box). }
    StaticX, StaticY: Single;
    { The available width it was last laid out for (incremental layout). }
    LastAvailableWidth: Single;
    LastAvailableHeight: Single;
    { Inline content (bfChildrenInline). }
    Inline: TInlineContent;
    { Scrolling (bfScrollContainer): the size of the scrollable
      overflow (from the padding box's origin) and the scroll offset. }
    ScrollWidth, ScrollHeight: Single;
    ScrollX, ScrollY: Single;
    { Baseline of the first and last line (relative to the border box;
      -1: none), for inline-block, flex and table baselines. }
    FirstBaseline, LastBaseline: Single;
    { Margin collapsing seen from outside (block boxes): the positive and
      negative margins that collapse through its top and bottom, and
      whether its own top and bottom margins collapse together. }
    TopPositive, TopNegative, BottomPositive, BottomNegative: Single;
    CollapsesThrough: Boolean;
    { The min-content and max-content border box widths, -1 when not
      known (forgotten when the box or something below it changes). }
    MinContentWidth, MaxContentWidth: Single;
    { The height its contents took (content box), whatever its own
      height says: table cells align their contents with it. }
    ContentExtent: Single;
    { Space above the border box that belongs to the box (a table's
      captions), after its collapsed top margin. }
    LeadingOffset: Single;
    constructor Create(AKind: TBoxKind; ANode: TNode; AStyle: TCssComputedStyle);
    destructor Destroy; override;
    procedure AppendChild(Child: TLayoutBox);
    procedure InsertBefore(Child, Before: TLayoutBox);
    procedure RemoveChild(Child: TLayoutBox);
    { Frees the children (and theirs). }
    procedure FreeChildren;
    function IsInlineLevel: Boolean; inline;
    function IsFloating: Boolean; inline;
    function IsAbsolutelyPositioned: Boolean; inline;
    function IsOutOfFlow: Boolean; inline;
    function IsPositioned: Boolean; inline;
    function IsBlockContainer: Boolean; inline;
    function IsAtomicInline: Boolean; inline;
    { Content box geometry. }
    function ContentLeft: Single; inline;
    function ContentTop: Single; inline;
    function ContentWidth: Single; inline;
    function ContentHeight: Single; inline;
    function MarginBoxWidth: Single; inline;
    function MarginBoxHeight: Single; inline;
    { Marks this box and the way up for layout. }
    procedure MarkNeedsLayout;
    { The nearest ancestor whose border box this box's X, Y are relative to. }
    function LayoutParent: TLayoutBox;
    { This box's border box origin relative to Ancestor's (an ancestor). }
    procedure OffsetFrom(Ancestor: TLayoutBox; out OffsetX, OffsetY: Single);
    { Relative to the viewport's origin (the document, unscrolled). }
    procedure AbsolutePosition(out PositionX, PositionY: Single);
  end;

  TTextBox = class(TLayoutBox)
  public
    { The text after white space processing and text-transform (set by
      inline layout). }
    Text: string;
    { The text as the DOM had it when Text was made. }
    SourceText: string;
    { Generated text (content, markers) instead of a text node's. }
    GeneratedText: string;
    IsGenerated: Boolean;
  end;

  TReplacedBox = class(TLayoutBox)
  public
    Image: TImage;
    { The image's natural size in CSS pixels when it is not its pixel
      size (scaled down when loaded, a srcset density); 0 otherwise. }
    NaturalWidth, NaturalHeight: Single;
    { From the image, else the element's attributes; 0 when none. }
    IntrinsicWidth, IntrinsicHeight: Single;
    HasIntrinsicWidth, HasIntrinsicHeight: Boolean;
    { width / height, 0 when none. }
    IntrinsicRatio: Single;
    { Form controls drawn by the painter. }
    ControlKind: Integer;
    { A frame's document (a TEmbeddedContent of the document's
      resources), nil for other replaced elements. }
    Content: TObject;
  end;

  TTableCellBox = class(TLayoutBox)
  public
    ColumnSpan, RowSpan: Integer;
    Column, Row: Integer;
  end;

function SideValue(const Edges: TBoxEdges; Side: TBoxSide): Single; inline;
{ Frees a box tree (without recursion). }
procedure FreeBoxTree(Root: TLayoutBox);
{ Moves a laid out box's contents (children, lines, fragments and
  baselines) down by Delta (a table cell's vertical-align, a button's
  centred content). }
procedure ShiftLayoutContents(Box: TLayoutBox; Delta: Single);

var
  LiveBoxCount: Int64 = 0;

implementation

uses
  Web.Style.NodeData;

function SideValue(const Edges: TBoxEdges; Side: TBoxSide): Single;
begin
  Result := Edges[Side];
end;

destructor TInlineContent.Destroy;
begin
  Items.Free;
  inherited Destroy;
end;

procedure TInlineContent.Clear;
begin
  LineCount := 0;
  FragmentCount := 0;
  EllipsisCount := 0;
  ItemsValid := False;
end;

function TInlineContent.AddFragment: PLineFragment;
begin
  if FragmentCount >= Length(Fragments) then
    SetLength(Fragments, FragmentCount * 2 + 8);
  Result := @Fragments[FragmentCount];
  FillChar(Result^, SizeOf(TLineFragment), 0);
  Inc(FragmentCount);
end;

procedure TInlineContent.AddLine(const Line: TLineBoxRecord);
begin
  if LineCount >= Length(Lines) then
    SetLength(Lines, LineCount * 2 + 4);
  Lines[LineCount] := Line;
  Inc(LineCount);
end;

constructor TLayoutBox.Create(AKind: TBoxKind; ANode: TNode; AStyle: TCssComputedStyle);
begin
  inherited Create;
  Kind := AKind;
  Node := ANode;
  Style := AStyle.AddRef;
  Flags := [bfNeedsLayout];
  FirstBaseline := -1;
  LastBaseline := -1;
  LastAvailableWidth := -1;
  MinContentWidth := -1;
  MaxContentWidth := -1;
  Inc(LiveBoxCount);
end;

destructor TLayoutBox.Destroy;
var
  Data: PNodeData;
begin
  if Node <> nil then
  begin
    Data := ExistingNodeData(Node);
    if (Data <> nil) and (Data^.Box = Self) then
      Data^.Box := nil;
  end;
  Inline.Free;
  Style.Release;
  Dec(LiveBoxCount);
  inherited Destroy;
end;

procedure TLayoutBox.AppendChild(Child: TLayoutBox);
begin
  Child.Parent := Self;
  Child.PreviousSibling := LastChild;
  Child.NextSibling := nil;
  if LastChild <> nil then
    LastChild.NextSibling := Child
  else
    FirstChild := Child;
  LastChild := Child;
end;

procedure TLayoutBox.InsertBefore(Child, Before: TLayoutBox);
begin
  if Before = nil then
  begin
    AppendChild(Child);
    Exit;
  end;
  Child.Parent := Self;
  Child.NextSibling := Before;
  Child.PreviousSibling := Before.PreviousSibling;
  if Before.PreviousSibling <> nil then
    Before.PreviousSibling.NextSibling := Child
  else
    FirstChild := Child;
  Before.PreviousSibling := Child;
end;

procedure TLayoutBox.RemoveChild(Child: TLayoutBox);
begin
  if Child.PreviousSibling <> nil then
    Child.PreviousSibling.NextSibling := Child.NextSibling
  else
    FirstChild := Child.NextSibling;
  if Child.NextSibling <> nil then
    Child.NextSibling.PreviousSibling := Child.PreviousSibling
  else
    LastChild := Child.PreviousSibling;
  Child.Parent := nil;
  Child.PreviousSibling := nil;
  Child.NextSibling := nil;
end;

{ Moves the boxes positioned relative to Box (its children, and those
  inside its inline boxes). }
procedure ShiftChildren(Box: TLayoutBox; Delta: Single);
var
  Child: TLayoutBox;
begin
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if Child.Kind = bkInline then
      ShiftChildren(Child, Delta)
    else
      Child.Y := Child.Y + Delta;
    Child := Child.NextSibling;
  end;
end;

procedure ShiftLayoutContents(Box: TLayoutBox; Delta: Single);
var
  Index: Integer;
begin
  if Delta = 0 then
    Exit;
  ShiftChildren(Box, Delta);
  if Box.Inline <> nil then
  begin
    for Index := 0 to Box.Inline.FragmentCount - 1 do
    begin
      Box.Inline.Fragments[Index].Y := Box.Inline.Fragments[Index].Y + Delta;
      Box.Inline.Fragments[Index].Baseline := Box.Inline.Fragments[Index].Baseline + Delta;
    end;
    for Index := 0 to Box.Inline.LineCount - 1 do
    begin
      Box.Inline.Lines[Index].Top := Box.Inline.Lines[Index].Top + Delta;
      Box.Inline.Lines[Index].Baseline := Box.Inline.Lines[Index].Baseline + Delta;
    end;
    for Index := 0 to Box.Inline.EllipsisCount - 1 do
      Box.Inline.Ellipses[Index].Baseline := Box.Inline.Ellipses[Index].Baseline + Delta;
    { Inline atomic boxes were moved with the children. }
  end;
  if Box.FirstBaseline >= 0 then
    Box.FirstBaseline := Box.FirstBaseline + Delta;
  if Box.LastBaseline >= 0 then
    Box.LastBaseline := Box.LastBaseline + Delta;
end;

procedure FreeBoxTree(Root: TLayoutBox);
var
  Box, Next: TLayoutBox;
begin
  if Root = nil then
    Exit;
  Box := Root;
  { Descend to leaves, freeing each box once its children are gone. }
  while True do
  begin
    while Box.FirstChild <> nil do
      Box := Box.FirstChild;
    if Box = Root then
    begin
      Root.Free;
      Exit;
    end;
    Next := Box.Parent;
    Next.FirstChild := Box.NextSibling;
    if Box.NextSibling = nil then
      Next.LastChild := nil
    else
      Box.NextSibling.PreviousSibling := nil;
    Box.Free;
    if Next.FirstChild <> nil then
      Box := Next.FirstChild
    else
      Box := Next;
  end;
end;

procedure TLayoutBox.FreeChildren;
var
  Child, Next: TLayoutBox;
begin
  Child := FirstChild;
  FirstChild := nil;
  LastChild := nil;
  while Child <> nil do
  begin
    Next := Child.NextSibling;
    Child.Parent := nil;
    Child.NextSibling := nil;
    Child.PreviousSibling := nil;
    FreeBoxTree(Child);
    Child := Next;
  end;
  if Inline <> nil then
    Inline.Clear;
end;

function TLayoutBox.IsInlineLevel: Boolean;
begin
  Result := bfInlineLevel in Flags;
end;

function TLayoutBox.IsFloating: Boolean;
begin
  Result := (bfFloatLeft in Flags) or (bfFloatRight in Flags);
end;

function TLayoutBox.IsAbsolutelyPositioned: Boolean;
begin
  Result := bfAbsolute in Flags;
end;

function TLayoutBox.IsOutOfFlow: Boolean;
begin
  Result := IsFloating or IsAbsolutelyPositioned;
end;

function TLayoutBox.IsPositioned: Boolean;
begin
  Result := (bfAbsolute in Flags) or (bfRelative in Flags);
end;

function TLayoutBox.IsBlockContainer: Boolean;
begin
  Result := Kind in [bkBlock, bkTableCell, bkTableCaption, bkViewport];
end;

function TLayoutBox.IsAtomicInline: Boolean;
begin
  Result := (bfInlineLevel in Flags) and not (Kind in [bkInline, bkText, bkLineBreak]);
end;

function TLayoutBox.ContentLeft: Single;
begin
  Result := Border[sideLeft] + Padding[sideLeft];
end;

function TLayoutBox.ContentTop: Single;
begin
  Result := Border[sideTop] + Padding[sideTop];
end;

function TLayoutBox.ContentWidth: Single;
begin
  Result := Width - Border[sideLeft] - Border[sideRight] - Padding[sideLeft] - Padding[sideRight];
  if Result < 0 then
    Result := 0;
end;

function TLayoutBox.ContentHeight: Single;
begin
  Result := Height - Border[sideTop] - Border[sideBottom] - Padding[sideTop] - Padding[sideBottom];
  if Result < 0 then
    Result := 0;
end;

function TLayoutBox.MarginBoxWidth: Single;
begin
  Result := Width + Margin[sideLeft] + Margin[sideRight];
end;

function TLayoutBox.MarginBoxHeight: Single;
begin
  Result := Height + Margin[sideTop] + Margin[sideBottom];
end;

procedure TLayoutBox.MarkNeedsLayout;
var
  Ancestor: TLayoutBox;
begin
  Include(Flags, bfNeedsLayout);
  MinContentWidth := -1;
  MaxContentWidth := -1;
  Ancestor := Parent;
  while Ancestor <> nil do
  begin
    Ancestor.MinContentWidth := -1;
    Ancestor.MaxContentWidth := -1;
    { Its inline items hold this box's measurements. }
    if Ancestor.Inline <> nil then
      Ancestor.Inline.ItemsValid := False;
    { All the way up: an ancestor may still carry the flag from a layout
      that did not reach it (stopping there left the root unaware, and
      lines kept pointing at boxes that were freed). }
    Include(Ancestor.Flags, bfChildNeedsLayout);
    Ancestor := Ancestor.Parent;
  end;
end;

function TLayoutBox.LayoutParent: TLayoutBox;
begin
  Result := Parent;
  while (Result <> nil) and (Result.Kind = bkInline) do
    Result := Result.Parent;
end;

procedure TLayoutBox.OffsetFrom(Ancestor: TLayoutBox; out OffsetX, OffsetY: Single);
var
  Box: TLayoutBox;
begin
  OffsetX := 0;
  OffsetY := 0;
  Box := Self;
  while (Box <> nil) and (Box <> Ancestor) do
  begin
    if Box.Kind <> bkInline then
    begin
      OffsetX := OffsetX + Box.X;
      OffsetY := OffsetY + Box.Y;
    end;
    Box := Box.Parent;
  end;
end;

procedure TLayoutBox.AbsolutePosition(out PositionX, PositionY: Single);
begin
  OffsetFrom(nil, PositionX, PositionY);
end;

end.

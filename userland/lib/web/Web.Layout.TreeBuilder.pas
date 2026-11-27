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
  Building the box tree from the DOM and the computed styles.

  display decides each element's box: none makes none, contents gives
  its children to its parent, the outer and inner display types pick
  the kind (block container, inline box, flex, grid, the table boxes),
  replaced elements (img, video, canvas, iframe, embed, object, and
  the form controls drawn by the engine) get replaced boxes. A
  list item gets a ::marker box, ::before and ::after with content get
  boxes holding generated text (resolved by Web.Layout.Counters).

  Then CSS's anonymous boxes: a block container with both block-level
  and inline-level children wraps each run of inline content in an
  anonymous block (a run of collapsible white space alone is dropped);
  one with only inline-level children has an inline formatting
  context. A block inside an inline box stays there (inline layout
  gives it lines of its own). Flex and grid items are blockified and
  text runs among them wrapped. Tables get the anonymous rows, row
  groups and cells their structure is missing.

  Rebuilding is per box: BuildChildren drops a box's children and
  builds them again from its node, which is what a DOM change under
  the node needs.
}
unit Web.Layout.TreeBuilder;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom, Css.ComputedStyle, Css.PointerMaps, Web.Layout.Boxes, Web.Style.Resolver, Web.Layout.Resources,
  Web.Svg.InlineImages, Image.Model;

type
  TBoxTreeBuilder = class
  private
    FStyler: TDocumentStyler;
    FResources: TDocumentResources;
    FAnonymousStyles: TCssPointerMap;
    FKeptStyles: array of TCssComputedStyle;
    { The children BuildChildren took away, which boxes may be reused from. }
    FOldChildren: array of TLayoutBox;
    { The box each of FOldChildren was taken from. }
    FOldParents: array of TLayoutBox;
    FBuildDepth: Integer;
    { The images of inline <svg> elements. }
    FInlineSvgs: TInlineSvgImages;
    function TakeReusableBox(Node: TNode; Parent: TLayoutBox): TLayoutBox;
    function NewAnonymousBlock(Parent: TLayoutBox): TLayoutBox;
    procedure AddChildrenOf(Parent: TLayoutBox; Node: TNode);
    procedure AddNodeBox(Parent: TLayoutBox; Node: TNode);
    function MakeElementBox(Element: TElement; Style: TCssComputedStyle): TLayoutBox;
    procedure AddGeneratedBox(Parent: TLayoutBox; Element: TElement; PseudoStyle: TCssComputedStyle;
      Flag: TBoxFlag);
    procedure AddMarker(Parent: TLayoutBox; Element: TElement);
    procedure AddControlContent(Box: TLayoutBox; Element: TElement);
    procedure FixUpBlockContainer(Box: TLayoutBox);
    procedure FixUpFlexContainer(Box: TLayoutBox);
    procedure FixUpTable(Box: TLayoutBox);
    procedure FixUpTableRowGroup(Box: TLayoutBox);
    procedure FixUpTableRow(Box: TLayoutBox);
    procedure WrapMisparentedTableParts(Box: TLayoutBox);
    procedure FixUp(Box: TLayoutBox);
    procedure LinkToNode(Box: TLayoutBox; Node: TNode; Principal: Boolean);
  public
    constructor Create(Styler: TDocumentStyler; Resources: TDocumentResources);
    destructor Destroy; override;
    { The whole tree: a viewport box holding the root element's box. }
    function BuildTree(Document: TDocument): TLayoutBox;
    { Drops Box's children and builds them again from its node. }
    procedure BuildChildren(Box: TLayoutBox);
    procedure BuildChildrenAnew(Box: TLayoutBox);
    { The (cached) style of anonymous boxes under ParentStyle. }
    function AnonymousStyleFor(ParentStyle: TCssComputedStyle): TCssComputedStyle;
    { Forgets the cached anonymous styles. }
    { The image a replaced box of Element shows when the loader has none
      for it: an inline <svg>'s drawing (nil for anything else). }
    function OwnImageOf(Element: TElement): TImage;
    procedure ClearCaches;
    property Styler: TDocumentStyler read FStyler;
  end;

{ Collapsible white space only (spaces, tabs, line feeds). }
function IsWhiteSpaceOnly(const Text: string): Boolean;
{ The replaced elements (and engine-drawn controls) and what they are. }
function ReplacedControlKind(Element: TElement): Integer;

const
  ControlImage = 0;
  ControlTextField = 1;
  ControlCheckbox = 2;
  ControlRadio = 3;
  ControlTextArea = 4;
  ControlMeter = 5;
  { input type=range: a track and a thumb at the value. }
  ControlRange = 6;
  ControlNone = -1;

implementation

uses
  SysUtils, Web.Atoms, Css.Keywords, Css.PropertyIds, Css.ComputedValues, Web.Style.NodeData, Web.Layout.Values,
  Web.Dom.FormControls, Web.Layout.ViewportOverflow, Web.Layout.LineClamp;

const
  { Boxes whose children are fixed up for them (FixUp). }
  FixedUpParentKinds = [bkFlex, bkGrid, bkTable, bkTableRowGroup, bkTableRow];

var
  AtomCanvasElement, AtomIframeElement, AtomEmbedElement, AtomObjectElement, AtomVideoElement,
  AtomAudioElement, AtomMeterElement, AtomProgressElement, AtomSvgElement: TAtom;

function IsWhiteSpaceOnly(const Text: string): Boolean;
var
  Index: Integer;
begin
  for Index := 1 to Length(Text) do
    if not (Text[Index] in [' ', #9, #10, #12, #13]) then
      Exit(False);
  Result := True;
end;

function ReplacedControlKind(Element: TElement): Integer;
var
  Name: TAtom;
  InputType: string;
begin
  Result := ControlNone;
  if Element.LocalNameAtom = AtomSvgElement then
    Exit(ControlImage);
  if not Element.IsHtml then
    Exit;
  Name := Element.LocalNameAtom;
  if (Name = AtomImg) or (Name = AtomCanvasElement) or (Name = AtomIframeElement) or (Name = AtomEmbedElement) or
     (Name = AtomVideoElement) or (Name = AtomObjectElement) or (Name = AtomFrame) then
    Exit(ControlImage);
  if (Name = AtomAudioElement) and Element.HasAttributeAtom(Atomize('controls')) then
    Exit(ControlImage);
  if Name = AtomTextarea then
    Exit(ControlTextArea);
  if (Name = AtomMeterElement) or (Name = AtomProgressElement) then
    Exit(ControlMeter);
  if Name = AtomInput then
  begin
    InputType := AsciiLowerCase(Element.AttributeValueOf(AtomType));
    if InputType = 'checkbox' then
      Exit(ControlCheckbox);
    if InputType = 'radio' then
      Exit(ControlRadio);
    if InputType = 'image' then
      Exit(ControlImage);
    if (InputType = 'range') then
      Exit(ControlRange);
    if (InputType = 'submit') or (InputType = 'reset') or (InputType = 'button') or (InputType = 'hidden') or
       (InputType = 'file') or (InputType = 'color') then
      Exit(ControlNone);
    Exit(ControlTextField);
  end;
end;

constructor TBoxTreeBuilder.Create(Styler: TDocumentStyler; Resources: TDocumentResources);
begin
  inherited Create;
  FStyler := Styler;
  FResources := Resources;
  FAnonymousStyles := TCssPointerMap.Create;
  FInlineSvgs := TInlineSvgImages.Create;
end;

destructor TBoxTreeBuilder.Destroy;
begin
  ClearCaches;
  FAnonymousStyles.Free;
  FInlineSvgs.Free;
  inherited Destroy;
end;

procedure TBoxTreeBuilder.ClearCaches;
var
  Index: Integer;
begin
  for Index := 0 to High(FKeptStyles) do
    FKeptStyles[Index].Release;
  FKeptStyles := nil;
  FAnonymousStyles.Clear;
end;

function TBoxTreeBuilder.OwnImageOf(Element: TElement): TImage;
begin
  Result := nil;
  if IsOutermostSvgElement(Element) then
    Result := FInlineSvgs.ImageFor(Element, FStyler);
end;

function TBoxTreeBuilder.AnonymousStyleFor(ParentStyle: TCssComputedStyle): TCssComputedStyle;
var
  Found: PtrInt;
begin
  if FAnonymousStyles.TryGet(ParentStyle, Found) then
    Exit(TCssComputedStyle(Found));
  Result := FStyler.AnonymousStyle(ParentStyle);
  { Keep the parent alive too: the map is keyed by its address. }
  SetLength(FKeptStyles, Length(FKeptStyles) + 2);
  FKeptStyles[High(FKeptStyles) - 1] := ParentStyle.AddRef;
  FKeptStyles[High(FKeptStyles)] := Result;
  FAnonymousStyles.Put(ParentStyle, PtrInt(Result));
end;

function TBoxTreeBuilder.NewAnonymousBlock(Parent: TLayoutBox): TLayoutBox;
begin
  Result := TLayoutBox.Create(bkBlock, nil, AnonymousStyleFor(Parent.Style));
  Include(Result.Flags, bfAnonymous);
end;

procedure TBoxTreeBuilder.LinkToNode(Box: TLayoutBox; Node: TNode; Principal: Boolean);
var
  Data: PNodeData;
begin
  Data := NodeDataOf(Node);
  if Principal then
  begin
    Box.NextForNode := nil;
    Data^.Box := Box;
  end
  else if Data^.Box <> nil then
  begin
    Box.NextForNode := TLayoutBox(Data^.Box).NextForNode;
    TLayoutBox(Data^.Box).NextForNode := Box;
  end;
end;

procedure SetPositionFlags(Box: TLayoutBox);
var
  Style: TCssComputedStyle;
  Position, FloatValue: TCssKeyword;
begin
  Style := Box.Style;
  Position := Style.Keyword(cpPosition);
  case Position of
    kwAbsolute: Box.Flags := Box.Flags + [bfAbsolute];
    kwFixed: Box.Flags := Box.Flags + [bfAbsolute, bfFixed];
    kwRelative: Include(Box.Flags, bfRelative);
    kwSticky: Box.Flags := Box.Flags + [bfRelative, bfSticky];
  end;
  if not (bfAbsolute in Box.Flags) then
  begin
    FloatValue := Style.Keyword(cpFloat);
    if KeywordIn(FloatValue, [kwLeft, kwInlineStart]) then
      Include(Box.Flags, bfFloatLeft)
    else if KeywordIn(FloatValue, [kwRight, kwInlineEnd]) then
      Include(Box.Flags, bfFloatRight);
  end;
  if Box.IsOutOfFlow then
  begin
    Exclude(Box.Flags, bfInlineLevel);
    if Box.Kind = bkInline then
      Box.Kind := bkBlock;
    Include(Box.Flags, bfNewFormattingContext);
  end;
  if OverflowClips(Style) and (Box.Kind <> bkInline) and
    not ((Box.Node is TElement) and PropagatesOverflowToViewport(TElement(Box.Node))) then
  begin
    Include(Box.Flags, bfClipsOverflow);
    if (Style.Keyword(cpOverflowX) <> kwClip) and (Style.Keyword(cpOverflowY) <> kwClip) then
      Box.Flags := Box.Flags + [bfScrollContainer, bfNewFormattingContext];
  end;
  if Style.Value(cpColumnCount)^.Kind in [cvInteger, cvNumber] then
    Include(Box.Flags, bfNewFormattingContext);
end;

function TBoxTreeBuilder.MakeElementBox(Element: TElement; Style: TCssComputedStyle): TLayoutBox;
var
  Display: TCssKeyword;
  Control: Integer;
  Replaced: TReplacedBox;
begin
  Result := nil;
  Display := DisplayKeyword(Style);
  if KeywordIn(Display, [kwNone, kwContents]) then
    Exit;
  Control := ReplacedControlKind(Element);
  if Control <> ControlNone then
  begin
    Replaced := TReplacedBox.Create(bkReplaced, Element, Style);
    Replaced.ControlKind := Control;
    if FResources <> nil then
    begin
      Replaced.Image := FResources.ElementImage(Element);
      FResources.ElementImageNaturalSize(Element, Replaced.NaturalWidth, Replaced.NaturalHeight);
    end;
    if Replaced.Image = nil then
      Replaced.Image := OwnImageOf(Element);
    if FResources <> nil then
      Replaced.Content := FResources.ElementFrame(Element);
    Result := Replaced;
    if not (KeywordIn(Display, [kwBlock, kwListItem, kwFlex, kwGrid, kwTable, kwFlowRoot])) then
      Include(Result.Flags, bfInlineLevel);
  end
  else
    case Display of
      kwInline, kwRuby, kwRubyBase, kwRubyText, kwRubyBaseContainer, kwRubyTextContainer, kwMath:
        if Element.IsHtmlElement(AtomBr) then
        begin
          Result := TLayoutBox.Create(bkLineBreak, Element, Style);
          Include(Result.Flags, bfInlineLevel);
        end
        else
        begin
          Result := TLayoutBox.Create(bkInline, Element, Style);
          Include(Result.Flags, bfInlineLevel);
        end;
      kwInlineBlock, kwInlineListItem:
        begin
          Result := TLayoutBox.Create(bkBlock, Element, Style);
          Result.Flags := Result.Flags + [bfInlineLevel, bfNewFormattingContext];
          if Display = kwInlineListItem then
            Include(Result.Flags, bfListItem);
        end;
      kwFlex, kwWebkitBox:
        if LineClampOf(Style) > 0 then
        begin
          { Legacy line clamping: a block container (Web.Layout.LineClamp). }
          Result := TLayoutBox.Create(bkBlock, Element, Style);
          Include(Result.Flags, bfNewFormattingContext);
        end
        else
          Result := TLayoutBox.Create(bkFlex, Element, Style);
      kwInlineFlex, kwWebkitInlineBox:
        begin
          if LineClampOf(Style) > 0 then
          begin
            Result := TLayoutBox.Create(bkBlock, Element, Style);
            Include(Result.Flags, bfNewFormattingContext);
          end
          else
            Result := TLayoutBox.Create(bkFlex, Element, Style);
          Include(Result.Flags, bfInlineLevel);
        end;
      kwGrid:
        Result := TLayoutBox.Create(bkGrid, Element, Style);
      kwInlineGrid:
        begin
          Result := TLayoutBox.Create(bkGrid, Element, Style);
          Include(Result.Flags, bfInlineLevel);
        end;
      kwTable:
        Result := TTableBox.Create(bkTable, Element, Style);
      kwInlineTable:
        begin
          Result := TTableBox.Create(bkTable, Element, Style);
          Include(Result.Flags, bfInlineLevel);
        end;
      kwTableRowGroup, kwTableHeaderGroup, kwTableFooterGroup:
        Result := TLayoutBox.Create(bkTableRowGroup, Element, Style);
      kwTableRow:
        Result := TLayoutBox.Create(bkTableRow, Element, Style);
      kwTableCell:
        Result := TTableCellBox.Create(bkTableCell, Element, Style);
      kwTableCaption:
        Result := TLayoutBox.Create(bkTableCaption, Element, Style);
      kwTableColumn:
        Result := TLayoutBox.Create(bkTableColumn, Element, Style);
      kwTableColumnGroup:
        Result := TLayoutBox.Create(bkTableColumnGroup, Element, Style);
      kwListItem:
        begin
          Result := TLayoutBox.Create(bkBlock, Element, Style);
          Include(Result.Flags, bfListItem);
        end;
      kwFlowRoot:
        begin
          Result := TLayoutBox.Create(bkBlock, Element, Style);
          Include(Result.Flags, bfNewFormattingContext);
        end;
    else
      Result := TLayoutBox.Create(bkBlock, Element, Style);
    end;
  if Result.Kind in [bkFlex, bkGrid, bkTable, bkTableCell, bkTableCaption] then
    Include(Result.Flags, bfNewFormattingContext);
  if Element = Element.NodeDocument.DocumentElement then
    Result.Flags := Result.Flags + [bfRootElement, bfNewFormattingContext];
  SetPositionFlags(Result);
end;

procedure TBoxTreeBuilder.AddGeneratedBox(Parent: TLayoutBox; Element: TElement; PseudoStyle: TCssComputedStyle;
  Flag: TBoxFlag);
var
  Content: PCssComputedValue;
  Box: TLayoutBox;
  Text: TTextBox;
  Display: TCssKeyword;
begin
  if PseudoStyle = nil then
    Exit;
  Content := PseudoStyle.Value(cpContent);
  if (Content^.Kind = cvKeyword) and (KeywordIn(TCssKeyword(Content^.Keyword), [kwNone, kwNormal])) then
    Exit;
  Display := DisplayKeyword(PseudoStyle);
  if Display = kwNone then
    Exit;
  if KeywordIn(Display, [kwInline, kwContents]) then
  begin
    Box := TLayoutBox.Create(bkInline, Element, PseudoStyle);
    Include(Box.Flags, bfInlineLevel);
  end
  else
  begin
    Box := TLayoutBox.Create(bkBlock, Element, PseudoStyle);
    if Display = kwInlineBlock then
      Box.Flags := Box.Flags + [bfInlineLevel, bfNewFormattingContext];
  end;
  Include(Box.Flags, Flag);
  SetPositionFlags(Box);
  Text := TTextBox.Create(bkText, nil, PseudoStyle);
  Text.Flags := Text.Flags + [bfInlineLevel, bfAnonymous];
  Text.IsGenerated := True;
  Box.AppendChild(Text);
  if Box.Kind = bkBlock then
    Include(Box.Flags, bfChildrenInline);
  Parent.AppendChild(Box);
  LinkToNode(Box, Element, False);
end;

procedure TBoxTreeBuilder.AddMarker(Parent: TLayoutBox; Element: TElement);
var
  Data: PNodeData;
  MarkerStyle: TCssComputedStyle;
  Box: TLayoutBox;
  Text: TTextBox;
  Content: PCssComputedValue;
  HasContent: Boolean;
begin
  Data := NodeDataOf(Element);
  MarkerStyle := Data^.MarkerStyle;
  if MarkerStyle = nil then
    MarkerStyle := AnonymousStyleFor(Parent.Style);
  Content := MarkerStyle.Value(cpContent);
  HasContent := not ((Content^.Kind = cvKeyword) and (KeywordIn(TCssKeyword(Content^.Keyword), [kwNone, kwNormal])));
  if (Content^.Kind = cvKeyword) and (TCssKeyword(Content^.Keyword) = kwNone) then
    Exit;
  if not HasContent and (Parent.Style.Keyword(cpListStyleType) = kwNone) and
     (Parent.Style.Value(cpListStyleType)^.Kind = cvKeyword) and
     (Parent.Style.Value(cpListStyleImage)^.Kind = cvKeyword) then
    Exit;
  if Parent.Style.Keyword(cpListStylePosition) <> kwInside then
  begin
    { Outside: a block of its own beside the first line. }
    Box := TLayoutBox.Create(bkBlock, Element, MarkerStyle);
    Box.Flags := Box.Flags + [bfMarker, bfOutsideMarker, bfNewFormattingContext, bfChildrenInline];
    Box.Inline := TInlineContent.Create;
  end
  else
  begin
    Box := TLayoutBox.Create(bkInline, Element, MarkerStyle);
    Box.Flags := Box.Flags + [bfInlineLevel, bfMarker];
  end;
  Text := TTextBox.Create(bkText, nil, MarkerStyle);
  Text.Flags := Text.Flags + [bfInlineLevel, bfAnonymous];
  Text.IsGenerated := True;
  Box.AppendChild(Text);
  Parent.AppendChild(Box);
  LinkToNode(Box, Element, False);
end;

procedure TBoxTreeBuilder.AddControlContent(Box: TLayoutBox; Element: TElement);
var
  Text: TTextBox;
  Value, InputType: string;
  Options: TNodeArray;
  Index: Integer;
begin
  Value := '';
  if Element.IsHtmlElement(AtomInput) then
  begin
    InputType := AsciiLowerCase(Element.AttributeValueOf(AtomType));
    if Element.HasAttributeAtom(AtomValue) then
      Value := Element.AttributeValueOf(AtomValue)
    else if InputType = 'submit' then
      Value := 'Submit'
    else if InputType = 'reset' then
      Value := 'Reset'
    else if InputType = 'file' then
      Value := 'Browse...'
    else
      Value := ' ';
  end
  else if Element.IsHtmlElement(AtomSelect) then
  begin
    { The selected option (the form control state's selectedness, which
      script and the user change), and the drop-down arrow unless the
      page draws its own (appearance: none). }
    Options := SelectOptions(Element);
    Index := SelectSelectedIndex(Element);
    if (Index >= 0) and (Index <= High(Options)) then
      Value := Trim(DescendantTextContent(Options[Index]));
    if Box.Style.Keyword(cpAppearance) <> kwNone then
      Value := Value + ' '#$E2#$96#$BE
    else if Value = '' then
      Value := ' ';
  end
  else
    Exit;
  Text := TTextBox.Create(bkText, nil, Box.Style);
  Text.Flags := Text.Flags + [bfInlineLevel, bfAnonymous];
  Text.IsGenerated := True;
  Text.GeneratedText := Value;
  Box.AppendChild(Text);
end;

{ The node's existing box if nothing about it changed (it is moved over
  instead of built again), else nil. }
function TBoxTreeBuilder.TakeReusableBox(Node: TNode; Parent: TLayoutBox): TLayoutBox;
var
  Data: PNodeData;
  Index, OldIndex: Integer;
  OldParent: TLayoutBox;
  KeptFlags: TBoxFlags;
begin
  Result := nil;
  Data := ExistingNodeData(Node);
  if (Data = nil) or (Data^.Box = nil) then
    Exit;
  if [ndBoxesDirty, ndDescendantBoxesDirty, ndStyleDirty] * Data^.Flags <> [] then
    Exit;
  Result := TLayoutBox(Data^.Box);
  if Node.IsText then
  begin
    if (StyleParentOf(Node) = nil) or (Result.Style <> StyleOf(StyleParentOf(Node))) then
      Exit(nil);
  end
  else if Result.Style <> Data^.Style then
    Exit(nil);
  OldParent := Result.Parent;
  OldIndex := -1;
  if OldParent = nil then
    for Index := 0 to High(FOldChildren) do
      if FOldChildren[Index] = Result then
      begin
        OldIndex := Index;
        Break;
      end;
  { The children of flex, grid and table boxes were fixed up for them
    (blockified, wrapped): not moved to or from another parent. A flex
    or grid box building its own children again takes back its items
    (the same fix-up applies). }
  if (Parent.Kind in FixedUpParentKinds) and
     not ((Parent.Kind in [bkFlex, bkGrid]) and (OldIndex >= 0) and (FOldParents[OldIndex] = Parent)) then
    Exit(nil);
  if (OldParent <> nil) and (OldParent.Kind in FixedUpParentKinds) then
    Exit(nil);
  { Not one of the boxes being rebuilt's ancestors. }
  if (Result = Parent) then
    Exit(nil);
  if OldParent <> nil then
    OldParent.RemoveChild(Result)
  else if OldIndex >= 0 then
    FOldChildren[OldIndex] := nil;
  { Its new ancestors are laid out again; the box itself only if it was
    to be already (a new size or translation in its style), and what it
    knew about itself (its measured size, that it has no counters) still
    holds. }
  KeptFlags := Result.Flags * [bfNeedsLayout, bfMeasured, bfCounterFree];
  Result.MarkNeedsLayout;
  Result.Flags := Result.Flags - [bfNeedsLayout, bfMeasured, bfCounterFree] + KeptFlags;
end;

procedure TBoxTreeBuilder.AddNodeBox(Parent: TLayoutBox; Node: TNode);
var
  Element: TElement;
  Data: PNodeData;
  Box: TLayoutBox;
  Text: TTextBox;
begin
  Box := TakeReusableBox(Node, Parent);
  if Box <> nil then
  begin
    Parent.AppendChild(Box);
    Exit;
  end;
  if Node.IsText then
  begin
    if TCharacterData(Node).Data = '' then
      Exit;
    if (StyleParentOf(Node) <> nil) and (StyleOf(StyleParentOf(Node)) <> nil) then
      Text := TTextBox.Create(bkText, Node, StyleOf(StyleParentOf(Node)))
    else
      Text := TTextBox.Create(bkText, Node, Parent.Style);
    Include(Text.Flags, bfInlineLevel);
    Parent.AppendChild(Text);
    LinkToNode(Text, Node, True);
    Exit;
  end;
  if not Node.IsElement then
    Exit;
  Element := TElement(Node);
  Data := NodeDataOf(Element);
  if (Data^.Style = nil) or (ndStyleDirty in Data^.Flags) then
    Exit;
  if DisplayKeyword(Data^.Style) = kwContents then
  begin
    AddGeneratedBox(Parent, Element, Data^.BeforeStyle, bfBefore);
    AddChildrenOf(Parent, Element);
    AddGeneratedBox(Parent, Element, Data^.AfterStyle, bfAfter);
    Exclude(Data^.Flags, ndBoxesDirty);
    Exit;
  end;
  Box := MakeElementBox(Element, Data^.Style);
  if Box = nil then
  begin
    Data^.Box := nil;
    Data^.Flags := Data^.Flags - [ndBoxesDirty, ndDescendantBoxesDirty];
    Exit;
  end;
  Parent.AppendChild(Box);
  Data^.Box := nil;
  LinkToNode(Box, Element, True);
  BuildChildren(Box);
end;

{ A details element that is not open shows only its summary (the first
  summary child; HTML renders the rest in a slot that is not shown). }
function IsClosedDetails(Node: TNode): Boolean;
begin
  Result := Node.IsElement and TElement(Node).IsHtmlElement(AtomDetails) and
    not TElement(Node).HasAttribute('open');
end;

function FirstSummaryOf(Node: TNode): TNode;
begin
  Result := Node.FirstChild;
  while (Result <> nil) and not (Result.IsElement and TElement(Result).IsHtmlElement(AtomSummary)) do
    Result := Result.NextSibling;
end;

procedure TBoxTreeBuilder.AddChildrenOf(Parent: TLayoutBox; Node: TNode);
var
  Child: TNode;
  Cursor: TFlatTreeCursor;
begin
  if IsClosedDetails(Node) then
  begin
    Child := FirstSummaryOf(Node);
    if Child <> nil then
      AddNodeBox(Parent, Child);
    Exit;
  end;
  { The flat tree: a host shows its shadow tree, a slot its assigned
    nodes (or its own children when none are). }
  Child := FlatTreeFirstChild(Node, Cursor);
  while Child <> nil do
  begin
    AddNodeBox(Parent, Child);
    Child := FlatTreeNextChild(Cursor);
  end;
end;

procedure TBoxTreeBuilder.BuildChildren(Box: TLayoutBox);
var
  Element: TElement;
  Data: PNodeData;
  Child, Next: TLayoutBox;
  Count, Index: Integer;
begin
  { Take the children away (their boxes may be reused), build anew,
    then (at the outermost call) free what was not reused. }
  if FBuildDepth = 0 then
  begin
    FOldChildren := nil;
    FOldParents := nil;
  end;
  Count := Length(FOldChildren);
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    Next := Child.NextSibling;
    SetLength(FOldChildren, Count + 1);
    SetLength(FOldParents, Count + 1);
    FOldChildren[Count] := Child;
    FOldParents[Count] := Box;
    Inc(Count);
    Child.Parent := nil;
    Child.NextSibling := nil;
    Child.PreviousSibling := nil;
    Child := Next;
  end;
  Box.FirstChild := nil;
  Box.LastChild := nil;
  if Box.Inline <> nil then
    Box.Inline.Clear;
  Box.NextForNode := nil;
  Inc(FBuildDepth);
  try
    BuildChildrenAnew(Box);
  finally
    Dec(FBuildDepth);
    if FBuildDepth = 0 then
    begin
      for Index := 0 to High(FOldChildren) do
        if FOldChildren[Index] <> nil then
          FreeBoxTree(FOldChildren[Index]);
      FOldChildren := nil;
      FOldParents := nil;
    end;
  end;
end;

procedure TBoxTreeBuilder.BuildChildrenAnew(Box: TLayoutBox);
var
  Element: TElement;
  Data: PNodeData;
begin
  Box.MarkNeedsLayout;
  if (Box.Node = nil) or not Box.Node.IsElement then
    Exit;
  Element := TElement(Box.Node);
  Data := NodeDataOf(Element);
  if Box.Kind = bkReplaced then
  begin
    { Inline SVG draws its subtree: a change there is a new image. }
    if IsOutermostSvgElement(Element) then
      TReplacedBox(Box).Image := OwnImageOf(Element);
    Data^.Flags := Data^.Flags - [ndBoxesDirty, ndDescendantBoxesDirty];
    Exit;
  end;
  if bfListItem in Box.Flags then
    AddMarker(Box, Element);
  AddGeneratedBox(Box, Element, Data^.BeforeStyle, bfBefore);
  if Element.IsHtmlElement(AtomInput) or Element.IsHtmlElement(AtomSelect) then
    AddControlContent(Box, Element)
  else
    AddChildrenOf(Box, Element);
  AddGeneratedBox(Box, Element, Data^.AfterStyle, bfAfter);
  Data^.Flags := Data^.Flags - [ndBoxesDirty, ndDescendantBoxesDirty];
  FixUp(Box);
end;

function TBoxTreeBuilder.BuildTree(Document: TDocument): TLayoutBox;
var
  Root: TElement;
begin
  Result := TLayoutBox.Create(bkViewport, nil, nil);
  Result.Flags := Result.Flags + [bfAnonymous, bfNewFormattingContext, bfScrollContainer];
  { The viewport has a style even before the document has a root (a
    page committed before its first bytes are parsed is laid out). }
  Result.Style := FStyler.AnonymousStyle(nil);
  Root := Document.DocumentElement;
  if (Root <> nil) and (StyleOf(Root) <> nil) then
    AddNodeBox(Result, Root);
end;

{ ---- anonymous boxes ---- }

function IsInlineContent(Box: TLayoutBox): Boolean;
begin
  Result := (bfInlineLevel in Box.Flags) or Box.IsOutOfFlow;
end;

function IsCollapsibleWhiteSpaceBox(Box: TLayoutBox): Boolean;
var
  WhiteSpace: TCssKeyword;
begin
  Result := False;
  if (Box.Kind <> bkText) or (Box.Node = nil) then
    Exit;
  WhiteSpace := Box.Style.Keyword(cpWhiteSpace);
  if KeywordIn(WhiteSpace, [kwPre, kwPreWrap, kwBreakSpaces, kwPreLine]) then
    Exit;
  Result := IsWhiteSpaceOnly(TCharacterData(Box.Node).Data);
end;

procedure TBoxTreeBuilder.FixUpBlockContainer(Box: TLayoutBox);
var
  Child, Next, Run: TLayoutBox;
  HasBlock, HasInline: Boolean;
begin
  HasBlock := False;
  HasInline := False;
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if (bfInlineLevel in Child.Flags) and not (bfOutsideMarker in Child.Flags) then
      HasInline := True
    else if not Child.IsOutOfFlow and not (bfOutsideMarker in Child.Flags) then
      HasBlock := True;
    Child := Child.NextSibling;
  end;
  if not HasBlock then
  begin
    Include(Box.Flags, bfChildrenInline);
    if Box.Inline = nil then
      Box.Inline := TInlineContent.Create;
    Exit;
  end;
  Exclude(Box.Flags, bfChildrenInline);
  if not HasInline then
    Exit;
  { Wrap each run of inline content (with the floats and absolutely
    positioned boxes among it) in an anonymous block. }
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if not IsInlineContent(Child) or (bfOutsideMarker in Child.Flags) then
    begin
      Child := Child.NextSibling;
      Continue;
    end;
    Run := Child;
    { A run that is only collapsible white space is dropped. }
    Next := Run;
    HasInline := False;
    while (Next <> nil) and IsInlineContent(Next) and not (bfOutsideMarker in Next.Flags) do
    begin
      if not IsCollapsibleWhiteSpaceBox(Next) and (bfInlineLevel in Next.Flags) then
        HasInline := True;
      Next := Next.NextSibling;
    end;
    if not HasInline then
    begin
      { Keep the out-of-flow boxes, drop the white space. }
      while Run <> Next do
      begin
        Child := Run.NextSibling;
        if IsCollapsibleWhiteSpaceBox(Run) then
        begin
          Box.RemoveChild(Run);
          FreeBoxTree(Run);
        end;
        Run := Child;
      end;
      Child := Next;
      Continue;
    end;
    Child := NewAnonymousBlock(Box);
    Box.InsertBefore(Child, Run);
    while Run <> Next do
    begin
      Box.RemoveChild(Run);
      Child.AppendChild(Run);
      Run := Child.NextSibling;
    end;
    Include(Child.Flags, bfChildrenInline);
    Child.Inline := TInlineContent.Create;
    Child := Next;
  end;
end;

procedure Blockify(Box: TLayoutBox);
begin
  Exclude(Box.Flags, bfInlineLevel);
  if Box.Kind = bkInline then
    Box.Kind := bkBlock;
  Include(Box.Flags, bfNewFormattingContext);
end;

{ Whether the contiguous text boxes from First on hold only white space. }
function IsWhiteSpaceOnlyTextRun(First: TLayoutBox): Boolean;
begin
  while (First <> nil) and (First.Kind = bkText) do
  begin
    if (First.Node = nil) or not IsWhiteSpaceOnly(TCharacterData(First.Node).Data) then
      Exit(False);
    First := First.NextSibling;
  end;
  Result := True;
end;

procedure TBoxTreeBuilder.FixUpFlexContainer(Box: TLayoutBox);
var
  Child, Next, Wrapper: TLayoutBox;
begin
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    Next := Child.NextSibling;
    if Child.Kind = bkText then
    begin
      { CSS Flexbox 4 and Grid 6: a run of text children that is only
        white space is not rendered, whatever white-space says. }
      if IsWhiteSpaceOnlyTextRun(Child) then
      begin
        while (Child <> nil) and (Child.Kind = bkText) do
        begin
          Next := Child.NextSibling;
          Box.RemoveChild(Child);
          FreeBoxTree(Child);
          Child := Next;
        end;
        Continue;
      end
      else
      begin
        { A run of text becomes one anonymous flex item. }
        Wrapper := NewAnonymousBlock(Box);
        Include(Wrapper.Flags, bfNewFormattingContext);
        Box.InsertBefore(Wrapper, Child);
        while (Child <> nil) and (Child.Kind = bkText) do
        begin
          Next := Child.NextSibling;
          Box.RemoveChild(Child);
          Wrapper.AppendChild(Child);
          Child := Next;
        end;
        Include(Wrapper.Flags, bfChildrenInline);
        Wrapper.Inline := TInlineContent.Create;
      end;
    end
    else if not Child.IsAbsolutelyPositioned then
    begin
      Blockify(Child);
      if Child.Kind = bkBlock then
        FixUpBlockContainer(Child);
    end;
    Child := Next;
  end;
end;

function IsTablePart(Box: TLayoutBox): Boolean;
begin
  Result := Box.Kind in [bkTableRowGroup, bkTableRow, bkTableCell, bkTableCaption, bkTableColumn,
    bkTableColumnGroup];
end;

procedure TBoxTreeBuilder.FixUpTableRow(Box: TLayoutBox);
var
  Child, Next, Cell: TLayoutBox;
begin
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    Next := Child.NextSibling;
    if Child.Kind <> bkTableCell then
    begin
      if IsCollapsibleWhiteSpaceBox(Child) or Child.IsAbsolutelyPositioned then
      begin
        if not Child.IsAbsolutelyPositioned then
        begin
          Box.RemoveChild(Child);
          FreeBoxTree(Child);
        end;
      end
      else
      begin
        Cell := TTableCellBox.Create(bkTableCell, nil, AnonymousStyleFor(Box.Style));
        Cell.Flags := Cell.Flags + [bfAnonymous, bfNewFormattingContext];
        Box.InsertBefore(Cell, Child);
        while (Child <> nil) and (Child.Kind <> bkTableCell) do
        begin
          Next := Child.NextSibling;
          Box.RemoveChild(Child);
          Cell.AppendChild(Child);
          Child := Next;
        end;
        FixUpBlockContainer(Cell);
      end;
    end;
    Child := Next;
  end;
end;

procedure TBoxTreeBuilder.FixUpTableRowGroup(Box: TLayoutBox);
var
  Child, Next, Row: TLayoutBox;
begin
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    Next := Child.NextSibling;
    if Child.Kind <> bkTableRow then
    begin
      if IsCollapsibleWhiteSpaceBox(Child) then
      begin
        Box.RemoveChild(Child);
        FreeBoxTree(Child);
      end
      else if not Child.IsAbsolutelyPositioned then
      begin
        Row := TLayoutBox.Create(bkTableRow, nil, AnonymousStyleFor(Box.Style));
        Include(Row.Flags, bfAnonymous);
        Box.InsertBefore(Row, Child);
        while (Child <> nil) and (Child.Kind <> bkTableRow) do
        begin
          Next := Child.NextSibling;
          Box.RemoveChild(Child);
          Row.AppendChild(Child);
          Child := Next;
        end;
        FixUpTableRow(Row);
      end;
    end;
    Child := Next;
  end;
end;

procedure TBoxTreeBuilder.FixUpTable(Box: TLayoutBox);
var
  Child, Next, Group: TLayoutBox;
begin
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    Next := Child.NextSibling;
    if not (Child.Kind in [bkTableRowGroup, bkTableCaption, bkTableColumn, bkTableColumnGroup]) then
    begin
      if IsCollapsibleWhiteSpaceBox(Child) then
      begin
        Box.RemoveChild(Child);
        FreeBoxTree(Child);
      end
      else if not Child.IsAbsolutelyPositioned then
      begin
        Group := TLayoutBox.Create(bkTableRowGroup, nil, AnonymousStyleFor(Box.Style));
        Include(Group.Flags, bfAnonymous);
        Box.InsertBefore(Group, Child);
        while (Child <> nil) and not (Child.Kind in [bkTableRowGroup, bkTableCaption, bkTableColumn,
          bkTableColumnGroup]) do
        begin
          Next := Child.NextSibling;
          Box.RemoveChild(Child);
          Group.AppendChild(Child);
          Child := Next;
        end;
        FixUpTableRowGroup(Group);
      end;
    end;
    Child := Next;
  end;
end;

{ CSS 2.2 17.2.1, "generate missing parents": a run of table parts (rows,
  row groups, cells, captions, columns, with the white space between
  them) whose parent is not a table part gets an anonymous table around
  it, an inline-level one in an inline box; the table's own fix-up then
  adds the row groups, rows and cells it misses. }
procedure TBoxTreeBuilder.WrapMisparentedTableParts(Box: TLayoutBox);
var
  Child, Next, Last, Table: TLayoutBox;
begin
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if not IsTablePart(Child) or Child.IsOutOfFlow then
    begin
      Child := Child.NextSibling;
      Continue;
    end;
    { The run ends at its last table part. }
    Last := Child;
    Next := Child.NextSibling;
    while (Next <> nil) and ((IsTablePart(Next) and not Next.IsOutOfFlow) or IsCollapsibleWhiteSpaceBox(Next)) do
    begin
      if IsTablePart(Next) then
        Last := Next;
      Next := Next.NextSibling;
    end;
    Table := TTableBox.Create(bkTable, nil, AnonymousStyleFor(Box.Style));
    Table.Flags := Table.Flags + [bfAnonymous, bfNewFormattingContext];
    if Box.Kind = bkInline then
      Include(Table.Flags, bfInlineLevel);
    Box.InsertBefore(Table, Child);
    repeat
      Next := Child.NextSibling;
      Box.RemoveChild(Child);
      Table.AppendChild(Child);
      if Child = Last then
        Break;
      Child := Next;
    until False;
    FixUpTable(Table);
    Child := Table.NextSibling;
  end;
end;

procedure TBoxTreeBuilder.FixUp(Box: TLayoutBox);
begin
  if Box.Kind in [bkBlock, bkInline, bkTableCell, bkTableCaption, bkFlex, bkGrid] then
    WrapMisparentedTableParts(Box);
  case Box.Kind of
    bkBlock, bkTableCell, bkTableCaption:
      FixUpBlockContainer(Box);
    bkFlex, bkGrid:
      FixUpFlexContainer(Box);
    bkTable:
      FixUpTable(Box);
    bkTableRowGroup:
      FixUpTableRowGroup(Box);
    bkTableRow:
      FixUpTableRow(Box);
  end;
end;

initialization
  AtomCanvasElement := Atomize('canvas');
  AtomIframeElement := Atomize('iframe');
  AtomEmbedElement := Atomize('embed');
  AtomObjectElement := Atomize('object');
  AtomVideoElement := Atomize('video');
  AtomAudioElement := Atomize('audio');
  AtomMeterElement := Atomize('meter');
  AtomProgressElement := Atomize('progress');
  AtomSvgElement := Atomize('svg');
end.

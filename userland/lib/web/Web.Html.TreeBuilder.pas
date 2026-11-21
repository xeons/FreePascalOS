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
  HTML tree construction (HTML Standard 13.2.6): the dispatcher, every
  insertion mode, the stack of open elements and the list of active
  formatting elements, the adoption agency algorithm, foster parenting,
  template contents, foreign content (SVG and MathML) with its
  adjustments, the document mode from the DOCTYPE, and the fragment
  case. Parse errors are counted, never fatal.

  Character tokens arrive as runs; the insertion modes that treat
  whitespace and other characters differently split the run.

  Where scripts come in (phase 2): a script end tag calls OnScriptEnd,
  which may stop the tokenizer (the parser pauses there and resumes,
  possibly after document.write put more input in); a meta charset calls
  OnEncodingDeclared. With scripting off (the default) noscript is parsed
  as markup, as the standard says for that case.

  The insertion modes are in include files: Web.Html.TreeBuilderHead.inc
  (initial up to after head), ...Body.inc, ...Tables.inc,
  ...Select.inc (select, template), ...After.inc (text, after body,
  framesets), ...Foreign.inc.
}
unit Web.Html.TreeBuilder;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Atoms,
  Web.Namespaces,
  Web.TextBuffers,
  Web.Dom,
  Web.Html.Tokens,
  Web.Html.Tokenizer,
  Web.Html.ElementKinds,
  Web.Html.ElementStack,
  Web.Html.FormattingList;

type
  TInsertionMode = (
    ImInitial, ImBeforeHtml, ImBeforeHead, ImInHead, ImInHeadNoscript, ImAfterHead, ImInBody, ImText,
    ImInTable, ImInTableText, ImInCaption, ImInColumnGroup, ImInTableBody, ImInRow, ImInCell, ImInSelect,
    ImInSelectInTable, ImInTemplate, ImAfterBody, ImInFrameset, ImAfterFrameset, ImAfterAfterBody,
    ImAfterAfterFrameset);

  TScriptEndEvent = procedure(Script: TElement) of object;
  { A meta element declared an encoding: its charset attribute, or with
    FromContent the content attribute of a Content-Type pragma. }
  TEncodingDeclaredEvent = procedure(const Value: string; FromContent: Boolean) of object;

  THtmlTreeBuilder = class(TTokenSink)
  private
    FDocument: TDocument;
    FTokenizer: THtmlTokenizer;
    FMode: TInsertionMode;
    FOriginalMode: TInsertionMode;
    FTemplateModes: array of TInsertionMode;
    FTemplateModeCount: Integer;
    FOpenElements: TElementStack;
    FFormatting: TFormattingList;
    FHeadElement: TElement;
    FFormElement: TElement;
    FFramesetOk: Boolean;
    FFosterParenting: Boolean;
    FScriptingEnabled: Boolean;
    FContextElement: TElement;
    FPendingTableCharacters: TTextBuffer;
    FIgnoreNextLineFeed: Boolean;
    FErrorCount: SizeInt;
    FStopped: Boolean;
    FOnScriptEnd: TScriptEndEvent;
    FOnEncodingDeclared: TEncodingDeclaredEvent;
    FOnParseError: TParseErrorEvent;
    { Short whitespace-only texts ("\n  " between tags), shared by the
      text nodes that have them. }
    FWhitespaceTexts: array[0..63] of string;
    function SharedText(const Text: string): string;
    procedure ParseError(const Code: string);
    { The dispatcher. }
    procedure DispatchToken(var Token: TToken);
    procedure ProcessInMode(Mode: TInsertionMode; var Token: TToken);
    procedure Reprocess(Mode: TInsertionMode; var Token: TToken);
    function UsesInsertionModeRules(const Token: TToken): Boolean;
    { Nodes and where they go. }
    function CurrentNode: TElement; inline;
    function AdjustedCurrentNode: TElement;
    procedure AppropriatePlace(OverrideTarget: TNode; out Parent, Before: TNode);
    function CreateElementForToken(var Token: TToken; Namespace: TNamespaceId; IntendedParent: TNode): TElement;
    procedure InsertAt(Node, Parent, Before: TNode);
    function InsertHtmlElement(var Token: TToken): TElement;
    function InsertForeignElement(var Token: TToken; Namespace: TNamespaceId): TElement;
    function InsertHtmlElementNamed(Name: TAtom): TElement;
    procedure InsertCharacters(const Text: string);
    procedure InsertComment(const Text: string; Parent: TNode = nil);
    { The algorithms the insertion modes share. }
    procedure GenerateImpliedEndTags(Excluded: TAtom = AtomNone);
    procedure GenerateAllImpliedEndTagsThoroughly;
    procedure ClosePElement;
    procedure CloseIfPInButtonScope;
    procedure ResetInsertionMode;
    procedure ReconstructFormatting;
    function RunAdoptionAgency(var Token: TToken): Boolean;
    procedure ParseRawText(var Token: TToken; TokenizerState: TTokenizerState);
    procedure PushTemplateMode(Mode: TInsertionMode);
    procedure PopTemplateMode;
    function CurrentTemplateMode: TInsertionMode;
    procedure CopyMissingAttributes(var Token: TToken; Element: TElement);
    procedure StopParsing;
    { The insertion modes. }
    procedure ModeInitial(var Token: TToken);
    procedure ModeBeforeHtml(var Token: TToken);
    procedure ModeBeforeHead(var Token: TToken);
    procedure ModeInHead(var Token: TToken);
    procedure ModeInHeadNoscript(var Token: TToken);
    procedure ModeAfterHead(var Token: TToken);
    procedure ModeInBody(var Token: TToken);
    procedure BodyStartTag(var Token: TToken);
    procedure BodyEndTag(var Token: TToken);
    procedure BodyCharacters(var Token: TToken);
    procedure BodyEndOfFile(var Token: TToken);
    procedure AnyOtherEndTag(var Token: TToken);
    procedure ModeText(var Token: TToken);
    procedure ModeInTable(var Token: TToken);
    procedure ModeInTableText(var Token: TToken);
    procedure ModeInCaption(var Token: TToken);
    procedure ModeInColumnGroup(var Token: TToken);
    procedure ModeInTableBody(var Token: TToken);
    procedure ModeInRow(var Token: TToken);
    procedure ModeInCell(var Token: TToken);
    procedure ModeInSelect(var Token: TToken);
    procedure ModeInSelectInTable(var Token: TToken);
    procedure ModeInTemplate(var Token: TToken);
    procedure ModeAfterBody(var Token: TToken);
    procedure ModeInFrameset(var Token: TToken);
    procedure ModeAfterFrameset(var Token: TToken);
    procedure ModeAfterAfterBody(var Token: TToken);
    procedure ModeAfterAfterFrameset(var Token: TToken);
    procedure ProcessForeignContent(var Token: TToken);
    procedure ClearStackBackToTableContext;
    procedure ClearStackBackToTableBodyContext;
    procedure ClearStackBackToTableRowContext;
    procedure CloseCell;
    procedure ProcessInTableAnythingElse(var Token: TToken);
  public
    constructor Create(Document: TDocument);
    destructor Destroy; override;
    { Sets up the fragment case (the HTML fragment parsing algorithm) for
      a context element, after the tokenizer is attached. }
    procedure SetUpFragment(Context: TElement);
    procedure ProcessToken(var Token: TToken); override;
    function AdjustedCurrentNodeIsForeign: Boolean; override;
    property Tokenizer: THtmlTokenizer read FTokenizer write FTokenizer;
    property Document: TDocument read FDocument;
    property Mode: TInsertionMode read FMode;
    property ScriptingEnabled: Boolean read FScriptingEnabled write FScriptingEnabled;
    property ErrorCount: SizeInt read FErrorCount;
    property Stopped: Boolean read FStopped;
    property OpenElements: TElementStack read FOpenElements;
    property OnScriptEnd: TScriptEndEvent read FOnScriptEnd write FOnScriptEnd;
    property OnEncodingDeclared: TEncodingDeclaredEvent read FOnEncodingDeclared write FOnEncodingDeclared;
    property OnParseError: TParseErrorEvent read FOnParseError write FOnParseError;
  end;

const
  { Open elements beyond this depth are inserted beside, not inside. }
  MaximumTreeDepth = 512;

implementation

uses
  Web.Html.ForeignContent,
  Web.Html.Quirks;

constructor THtmlTreeBuilder.Create(Document: TDocument);
begin
  inherited Create;
  FDocument := Document;
  FOpenElements := TElementStack.Create;
  FFormatting := TFormattingList.Create;
  FPendingTableCharacters := TTextBuffer.Create;
  FFramesetOk := True;
  FMode := ImInitial;
end;

destructor THtmlTreeBuilder.Destroy;
begin
  FOpenElements.Free;
  FFormatting.Free;
  FPendingTableCharacters.Free;
  inherited Destroy;
end;

procedure THtmlTreeBuilder.ParseError(const Code: string);
begin
  Inc(FErrorCount);
  if Assigned(FOnParseError) then
    FOnParseError(Code);
end;

function IsWhitespaceByte(Value: Char): Boolean; inline;
begin
  Result := Value in [#9, #10, #12, #13, ' '];
end;

{ The length of the first character of Text (its lead byte and the
  continuation bytes after it). }
function FirstCharacterLength(const Text: string): Integer;
begin
  Result := 1;
  while (Result < Length(Text)) and (Result < 4) and ((Ord(Text[Result + 1]) and $C0) = $80) do
    Inc(Result);
end;

{ The length of the run of whitespace at the start of Text. }
function LeadingWhitespace(const Text: string): SizeInt;
begin
  Result := 0;
  while (Result < Length(Text)) and IsWhitespaceByte(Text[Result + 1]) do
    Inc(Result);
end;

function IsAllWhitespace(const Text: string): Boolean;
begin
  Result := LeadingWhitespace(Text) = Length(Text);
end;

{ Only the whitespace characters of Text. }
function WhitespaceOnly(const Text: string): string;
var
  Index: SizeInt;
begin
  Result := '';
  for Index := 1 to Length(Text) do
    if IsWhitespaceByte(Text[Index]) then
      Result := Result + Text[Index];
end;

function IsStartTag(const Token: TToken; Name: TAtom): Boolean; inline;
begin
  Result := (Token.Kind = TokenStartTag) and (Token.TagName = Name);
end;

function IsEndTag(const Token: TToken; Name: TAtom): Boolean; inline;
begin
  Result := (Token.Kind = TokenEndTag) and (Token.TagName = Name);
end;

function IsOneOf(Name: TAtom; const Names: array of TAtom): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Names) do
    if Names[Index] = Name then
      Exit(True);
  Result := False;
end;

{ A token made by the tree builder itself (an implied start tag). }
procedure MakeTagToken(out Token: TToken; Kind: TTokenKind; Name: TAtom);
begin
  Token := Default(TToken);
  Token.Kind := Kind;
  Token.TagName := Name;
end;

{ The dispatcher }

function THtmlTreeBuilder.CurrentNode: TElement;
begin
  Result := FOpenElements.Current;
end;

function THtmlTreeBuilder.AdjustedCurrentNode: TElement;
begin
  if (FContextElement <> nil) and (FOpenElements.Count = 1) then
    Result := FContextElement
  else
    Result := FOpenElements.Current;
end;

function THtmlTreeBuilder.AdjustedCurrentNodeIsForeign: Boolean;
var
  Node: TElement;
begin
  Node := AdjustedCurrentNode;
  Result := (Node <> nil) and not Node.IsHtml;
end;

function THtmlTreeBuilder.UsesInsertionModeRules(const Token: TToken): Boolean;
var
  Node: TElement;
begin
  if FOpenElements.Count = 0 then
    Exit(True);
  Node := AdjustedCurrentNode;
  if Node.IsHtml or (Token.Kind = TokenEndOfFile) then
    Exit(True);
  if IsMathMlTextIntegrationPoint(Node) then
  begin
    if (Token.Kind = TokenStartTag) and (Token.TagName <> AtomMglyph) and (Token.TagName <> AtomMalignmark) then
      Exit(True);
    if Token.Kind = TokenCharacters then
      Exit(True);
  end;
  if (Node.NamespaceAtom = AtomMathMlNamespace) and (Node.LocalNameAtom = AtomAnnotationXml) and
    IsStartTag(Token, AtomSvg) then
    Exit(True);
  if IsHtmlIntegrationPoint(Node) and (Token.Kind in [TokenStartTag, TokenCharacters]) then
    Exit(True);
  Result := False;
end;

procedure THtmlTreeBuilder.ProcessToken(var Token: TToken);
begin
  if FIgnoreNextLineFeed then
  begin
    FIgnoreNextLineFeed := False;
    if (Token.Kind = TokenCharacters) and (Token.Data <> '') and (Token.Data[1] = #10) then
    begin
      Delete(Token.Data, 1, 1);
      if Token.Data = '' then
        Exit;
    end;
  end;
  DispatchToken(Token);
end;

procedure THtmlTreeBuilder.DispatchToken(var Token: TToken);
begin
  if FStopped then
    Exit;
  if UsesInsertionModeRules(Token) then
    ProcessInMode(FMode, Token)
  else
    ProcessForeignContent(Token);
end;

procedure THtmlTreeBuilder.Reprocess(Mode: TInsertionMode; var Token: TToken);
begin
  FMode := Mode;
  DispatchToken(Token);
end;

procedure THtmlTreeBuilder.ProcessInMode(Mode: TInsertionMode; var Token: TToken);
begin
  case Mode of
    ImInitial: ModeInitial(Token);
    ImBeforeHtml: ModeBeforeHtml(Token);
    ImBeforeHead: ModeBeforeHead(Token);
    ImInHead: ModeInHead(Token);
    ImInHeadNoscript: ModeInHeadNoscript(Token);
    ImAfterHead: ModeAfterHead(Token);
    ImInBody: ModeInBody(Token);
    ImText: ModeText(Token);
    ImInTable: ModeInTable(Token);
    ImInTableText: ModeInTableText(Token);
    ImInCaption: ModeInCaption(Token);
    ImInColumnGroup: ModeInColumnGroup(Token);
    ImInTableBody: ModeInTableBody(Token);
    ImInRow: ModeInRow(Token);
    ImInCell: ModeInCell(Token);
    ImInSelect: ModeInSelect(Token);
    ImInSelectInTable: ModeInSelectInTable(Token);
    ImInTemplate: ModeInTemplate(Token);
    ImAfterBody: ModeAfterBody(Token);
    ImInFrameset: ModeInFrameset(Token);
    ImAfterFrameset: ModeAfterFrameset(Token);
    ImAfterAfterBody: ModeAfterAfterBody(Token);
    ImAfterAfterFrameset: ModeAfterAfterFrameset(Token);
  end;
end;

procedure THtmlTreeBuilder.StopParsing;
begin
  FStopped := True;
  FOpenElements.Clear;
end;

{ Creating and inserting nodes }

procedure THtmlTreeBuilder.AppropriatePlace(OverrideTarget: TNode; out Parent, Before: TNode);
var
  Target: TNode;
  LastTemplate, LastTable: Integer;
begin
  if OverrideTarget <> nil then
    Target := OverrideTarget
  else
    Target := CurrentNode;
  Before := nil;
  if FFosterParenting and (Target.NodeType = NodeTypeElement) and TElement(Target).IsHtml and
    IsOneOf(Target.LocalNameAtom, [AtomTable, AtomTbody, AtomTfoot, AtomThead, AtomTr]) then
  begin
    LastTemplate := FOpenElements.LastIndexOfHtml(AtomTemplate);
    LastTable := FOpenElements.LastIndexOfHtml(AtomTable);
    if (LastTemplate >= 0) and ((LastTable < 0) or (LastTemplate > LastTable)) then
      Parent := FOpenElements[LastTemplate]
    else if LastTable < 0 then
      Parent := FOpenElements[0]
    else if FOpenElements[LastTable].ParentNode <> nil then
    begin
      Parent := FOpenElements[LastTable].ParentNode;
      Before := FOpenElements[LastTable];
    end
    else
      Parent := FOpenElements[LastTable - 1];
  end
  else
    Parent := Target;
  { As deep as MaximumTreeDepth at most (as other engines do): deeper
    elements go beside their would-be parent, so styling, layout and
    painting, which walk the tree recursively, stay within the stack. }
  if (OverrideTarget = nil) and (FOpenElements.Count > MaximumTreeDepth) and (Parent.ParentNode <> nil) then
  begin
    Parent := Parent.ParentNode;
    Before := nil;
  end;
  if (Parent.NodeType = NodeTypeElement) and TElement(Parent).IsHtmlElement(AtomTemplate) then
  begin
    Parent := TElement(Parent).TemplateContent;
    Before := nil;
  end;
end;

function THtmlTreeBuilder.CreateElementForToken(var Token: TToken; Namespace: TNamespaceId;
  IntendedParent: TNode): TElement;
var
  Index: Integer;
  Attribute: ^TTokenAttribute;
begin
  Result := IntendedParent.NodeDocument.NewElement(Token.TagName, Namespace);
  for Index := 1 to Token.AttributeCount do
  begin
    Attribute := @Token.Attributes[Index - 1];
    Result.AddAttributeFromParser(Attribute^.LocalName, Attribute^.NamespaceId, Attribute^.Value);
  end;
  { Form owners of form-associated elements come with forms (phase 2). }
end;

procedure THtmlTreeBuilder.InsertAt(Node, Parent, Before: TNode);
begin
  Parent.InsertNodeBefore(Node, Before);
end;

function THtmlTreeBuilder.InsertForeignElement(var Token: TToken; Namespace: TNamespaceId): TElement;
var
  Parent, Before: TNode;
begin
  AppropriatePlace(nil, Parent, Before);
  Result := CreateElementForToken(Token, Namespace, Parent);
  InsertAt(Result, Parent, Before);
  FOpenElements.Push(Result);
end;

function THtmlTreeBuilder.InsertHtmlElement(var Token: TToken): TElement;
begin
  Result := InsertForeignElement(Token, NamespaceHtml);
end;

function THtmlTreeBuilder.InsertHtmlElementNamed(Name: TAtom): TElement;
var
  Token: TToken;
begin
  MakeTagToken(Token, TokenStartTag, Name);
  Result := InsertHtmlElement(Token);
end;

function THtmlTreeBuilder.SharedText(const Text: string): string;
var
  Index: SizeInt;
  Hash: LongWord;
begin
  Result := Text;
  if Length(Text) > 32 then
    Exit;
  Hash := Length(Text);
  for Index := 1 to Length(Text) do
  begin
    if not IsWhitespaceByte(Text[Index]) then
      Exit;
    Hash := (Hash * 7 + Ord(Text[Index])) and 63;
  end;
  if FWhitespaceTexts[Hash] <> Text then
    FWhitespaceTexts[Hash] := Text;
  Result := FWhitespaceTexts[Hash];
end;

procedure THtmlTreeBuilder.InsertCharacters(const Text: string);
var
  Parent, Before, Previous: TNode;
begin
  if Text = '' then
    Exit;
  AppropriatePlace(nil, Parent, Before);
  if Parent.NodeType = NodeTypeDocument then
    Exit;
  if Before = nil then
    Previous := Parent.LastChild
  else
    Previous := Before.PreviousSibling;
  if (Previous <> nil) and (Previous.NodeType = NodeTypeText) then
    TText(Previous).AppendDataFromParser(Text)
  else
    InsertAt(Parent.NodeDocument.NewText(SharedText(Text)), Parent, Before);
end;

procedure THtmlTreeBuilder.InsertComment(const Text: string; Parent: TNode);
var
  Before: TNode;
begin
  if Parent = nil then
    AppropriatePlace(nil, Parent, Before)
  else
    Before := nil;
  InsertAt(Parent.NodeDocument.NewComment(Text), Parent, Before);
end;

{ The shared algorithms }

procedure THtmlTreeBuilder.GenerateImpliedEndTags(Excluded: TAtom);
var
  Node: TElement;
begin
  while FOpenElements.Count > 0 do
  begin
    Node := CurrentNode;
    if not Node.IsHtml or ((HtmlKinds(Node.LocalNameAtom) and KindImpliedEndTag) = 0) or
      (Node.LocalNameAtom = Excluded) then
      Exit;
    FOpenElements.Pop;
  end;
end;

procedure THtmlTreeBuilder.GenerateAllImpliedEndTagsThoroughly;
var
  Node: TElement;
begin
  while FOpenElements.Count > 0 do
  begin
    Node := CurrentNode;
    if not Node.IsHtml or ((HtmlKinds(Node.LocalNameAtom) and KindImpliedEndTagThorough) = 0) then
      Exit;
    FOpenElements.Pop;
  end;
end;

procedure THtmlTreeBuilder.ClosePElement;
begin
  GenerateImpliedEndTags(AtomP);
  if not CurrentNode.IsHtmlElement(AtomP) then
    ParseError('unexpected-open-element');
  FOpenElements.PopUntilHtml(AtomP);
end;

procedure THtmlTreeBuilder.CloseIfPInButtonScope;
begin
  if FOpenElements.HasInScope(AtomP, ScopeButton) then
    ClosePElement;
end;

procedure THtmlTreeBuilder.PushTemplateMode(Mode: TInsertionMode);
begin
  if FTemplateModeCount >= Length(FTemplateModes) then
    SetLength(FTemplateModes, FTemplateModeCount * 2 + 4);
  FTemplateModes[FTemplateModeCount] := Mode;
  Inc(FTemplateModeCount);
end;

procedure THtmlTreeBuilder.PopTemplateMode;
begin
  if FTemplateModeCount > 0 then
    Dec(FTemplateModeCount);
end;

function THtmlTreeBuilder.CurrentTemplateMode: TInsertionMode;
begin
  Result := FTemplateModes[FTemplateModeCount - 1];
end;

procedure THtmlTreeBuilder.ResetInsertionMode;
var
  Index, AncestorIndex: Integer;
  Node, Ancestor: TElement;
  Last: Boolean;
  Name: TAtom;
begin
  Index := FOpenElements.Count - 1;
  while Index >= 0 do
  begin
    Node := FOpenElements[Index];
    Last := Index = 0;
    if Last and (FContextElement <> nil) then
      Node := FContextElement;
    if Node.IsHtml then
    begin
      Name := Node.LocalNameAtom;
      if Name = AtomSelect then
      begin
        if not Last then
        begin
          AncestorIndex := Index;
          while AncestorIndex > 0 do
          begin
            Dec(AncestorIndex);
            Ancestor := FOpenElements[AncestorIndex];
            if Ancestor.IsHtmlElement(AtomTemplate) then
              Break;
            if Ancestor.IsHtmlElement(AtomTable) then
            begin
              FMode := ImInSelectInTable;
              Exit;
            end;
          end;
        end;
        FMode := ImInSelect;
        Exit;
      end;
      if ((Name = AtomTd) or (Name = AtomTh)) and not Last then
      begin
        FMode := ImInCell;
        Exit;
      end;
      if Name = AtomTr then
      begin
        FMode := ImInRow;
        Exit;
      end;
      if (Name = AtomTbody) or (Name = AtomThead) or (Name = AtomTfoot) then
      begin
        FMode := ImInTableBody;
        Exit;
      end;
      if Name = AtomCaption then
      begin
        FMode := ImInCaption;
        Exit;
      end;
      if Name = AtomColgroup then
      begin
        FMode := ImInColumnGroup;
        Exit;
      end;
      if Name = AtomTable then
      begin
        FMode := ImInTable;
        Exit;
      end;
      if Name = AtomTemplate then
      begin
        FMode := CurrentTemplateMode;
        Exit;
      end;
      if (Name = AtomHead) and not Last then
      begin
        FMode := ImInHead;
        Exit;
      end;
      if Name = AtomBody then
      begin
        FMode := ImInBody;
        Exit;
      end;
      if Name = AtomFrameset then
      begin
        FMode := ImInFrameset;
        Exit;
      end;
      if Name = AtomHtml then
      begin
        if FHeadElement = nil then
          FMode := ImBeforeHead
        else
          FMode := ImAfterHead;
        Exit;
      end;
    end;
    if Last then
    begin
      FMode := ImInBody;
      Exit;
    end;
    Dec(Index);
  end;
  FMode := ImInBody;
end;

procedure THtmlTreeBuilder.ReconstructFormatting;
var
  Index: Integer;
  Entry: TFormattingEntry;
  Token: TToken;
  Element: TElement;
begin
  if FFormatting.Count = 0 then
    Exit;
  Index := FFormatting.Count - 1;
  if FFormatting.IsMarker(Index) or FOpenElements.Contains(FFormatting[Index].Element) then
    Exit;
  { Rewind to the entry after the last marker or open element. }
  while Index > 0 do
  begin
    Dec(Index);
    if FFormatting.IsMarker(Index) or FOpenElements.Contains(FFormatting[Index].Element) then
    begin
      Inc(Index);
      Break;
    end;
  end;
  { Create, advancing to the end. }
  while Index < FFormatting.Count do
  begin
    Entry := FFormatting[Index];
    Token := Default(TToken);
    Token.Kind := TokenStartTag;
    Token.TagName := Entry.TagName;
    Token.Attributes := Entry.Attributes;
    Token.AttributeCount := Length(Entry.Attributes);
    Element := InsertHtmlElement(Token);
    FFormatting.ReplaceElement(Index, Element);
    Inc(Index);
  end;
end;

{ The adoption agency algorithm: False when the token is to be handled
  as "any other end tag" instead. }
function THtmlTreeBuilder.RunAdoptionAgency(var Token: TToken): Boolean;
var
  Subject: TAtom;
  OuterLoop, InnerLoop, FormattingIndex, StackIndex, FurthestIndex, Bookmark, NodeIndex, Index: Integer;
  FormattingElement, FurthestBlock, CommonAncestor, Node, LastNode, NewElement: TElement;
  Entry, NewEntry: TFormattingEntry;
  NodeToken: TToken;
  Parent, Before, Child: TNode;
begin
  Subject := Token.TagName;
  if CurrentNode.IsHtmlElement(Subject) and not FFormatting.Contains(CurrentNode) then
  begin
    FOpenElements.Pop;
    Exit(True);
  end;
  OuterLoop := 0;
  while OuterLoop < 8 do
  begin
    Inc(OuterLoop);
    FormattingIndex := FFormatting.LastIndexAfterMarker(Subject);
    if FormattingIndex < 0 then
      Exit(False);
    Entry := FFormatting[FormattingIndex];
    FormattingElement := Entry.Element;
    StackIndex := FOpenElements.IndexOf(FormattingElement);
    if StackIndex < 0 then
    begin
      ParseError('adoption-agency-1.2');
      FFormatting.RemoveAt(FormattingIndex);
      Exit(True);
    end;
    if not FOpenElements.HasElementInScope(FormattingElement, ScopeDefault) then
    begin
      ParseError('adoption-agency-4.4');
      Exit(True);
    end;
    if FormattingElement <> CurrentNode then
      ParseError('adoption-agency-1.3');
    FurthestIndex := -1;
    for Index := StackIndex + 1 to FOpenElements.Count - 1 do
      if IsSpecialElement(FOpenElements[Index]) then
      begin
        FurthestIndex := Index;
        Break;
      end;
    if FurthestIndex < 0 then
    begin
      while FOpenElements.Count > StackIndex do
        FOpenElements.Pop;
      FFormatting.RemoveAt(FormattingIndex);
      Exit(True);
    end;
    FurthestBlock := FOpenElements[FurthestIndex];
    CommonAncestor := FOpenElements[StackIndex - 1];
    Bookmark := FormattingIndex;
    Node := FurthestBlock;
    LastNode := FurthestBlock;
    NodeIndex := FurthestIndex;
    InnerLoop := 0;
    while True do
    begin
      Inc(InnerLoop);
      Dec(NodeIndex);
      Node := FOpenElements[NodeIndex];
      if Node = FormattingElement then
        Break;
      Index := FFormatting.IndexOf(Node);
      if (InnerLoop > 3) and (Index >= 0) then
      begin
        FFormatting.RemoveAt(Index);
        if Index < Bookmark then
          Dec(Bookmark);
        Index := -1;
      end;
      if Index < 0 then
      begin
        FOpenElements.RemoveAt(NodeIndex);
        Continue;
      end;
      NodeToken := Default(TToken);
      NodeToken.Kind := TokenStartTag;
      NodeToken.TagName := FFormatting[Index].TagName;
      NodeToken.Attributes := FFormatting[Index].Attributes;
      NodeToken.AttributeCount := Length(NodeToken.Attributes);
      NewElement := CreateElementForToken(NodeToken, NamespaceHtml, CommonAncestor);
      FFormatting.ReplaceElement(Index, NewElement);
      FOpenElements.Replace(Node, NewElement);
      Node := NewElement;
      if LastNode = FurthestBlock then
        Bookmark := Index + 1;
      Node.InsertNodeBefore(LastNode, nil);
      LastNode := Node;
    end;
    AppropriatePlace(CommonAncestor, Parent, Before);
    InsertAt(LastNode, Parent, Before);
    NodeToken := Default(TToken);
    NodeToken.Kind := TokenStartTag;
    NodeToken.TagName := Entry.TagName;
    NodeToken.Attributes := Entry.Attributes;
    NodeToken.AttributeCount := Length(Entry.Attributes);
    NewElement := CreateElementForToken(NodeToken, NamespaceHtml, FurthestBlock);
    while FurthestBlock.FirstChild <> nil do
    begin
      Child := FurthestBlock.FirstChild;
      NewElement.InsertNodeBefore(Child, nil);
    end;
    FurthestBlock.InsertNodeBefore(NewElement, nil);
    NewEntry := Entry;
    NewEntry.Element := NewElement;
    Index := FFormatting.IndexOf(FormattingElement);
    if Index < Bookmark then
      Dec(Bookmark);
    FFormatting.RemoveAt(Index);
    FFormatting.InsertAt(Bookmark, NewEntry);
    FOpenElements.Remove(FormattingElement);
    FOpenElements.InsertAt(FOpenElements.IndexOf(FurthestBlock) + 1, NewElement);
  end;
  Result := True;
end;

procedure THtmlTreeBuilder.ParseRawText(var Token: TToken; TokenizerState: TTokenizerState);
begin
  InsertHtmlElement(Token);
  FTokenizer.SwitchTo(TokenizerState);
  FOriginalMode := FMode;
  FMode := ImText;
end;

procedure THtmlTreeBuilder.CopyMissingAttributes(var Token: TToken; Element: TElement);
var
  Index: Integer;
begin
  for Index := 1 to Token.AttributeCount do
    if not Element.HasAttributeAtom(Token.Attributes[Index - 1].Name) then
      Element.SetAttributeAtom(Token.Attributes[Index - 1].Name, NamespaceNone, Token.Attributes[Index - 1].Value);
end;

procedure THtmlTreeBuilder.SetUpFragment(Context: TElement);
var
  Root: TElement;
  Name: TAtom;
  Node: TNode;
begin
  FContextElement := Context;
  if Context.IsHtml then
  begin
    Name := Context.LocalNameAtom;
    if (Name = AtomTitle) or (Name = AtomTextarea) then
      FTokenizer.SwitchTo(TsRcdata)
    else if IsOneOf(Name, [AtomStyle, AtomXmp, AtomIframe, AtomNoembed, AtomNoframes]) then
      FTokenizer.SwitchTo(TsRawText)
    else if Name = AtomScript then
      FTokenizer.SwitchTo(TsScriptData)
    else if (Name = AtomNoscript) and FScriptingEnabled then
      FTokenizer.SwitchTo(TsRawText)
    else if Name = AtomPlaintext then
      FTokenizer.SwitchTo(TsPlainText);
  end;
  FTokenizer.LastStartTagName := Context.LocalNameAtom;
  Root := FDocument.NewElement(AtomHtml, NamespaceHtml);
  FDocument.InsertNodeBefore(Root, nil);
  FOpenElements.Push(Root);
  if Context.IsHtmlElement(AtomTemplate) then
    PushTemplateMode(ImInTemplate);
  ResetInsertionMode;
  Node := Context;
  while Node <> nil do
  begin
    if (Node.NodeType = NodeTypeElement) and TElement(Node).IsHtmlElement(AtomForm) then
    begin
      FFormElement := TElement(Node);
      Break;
    end;
    Node := Node.ParentNode;
  end;
end;

{$I Web.Html.TreeBuilderHead.inc}
{$I Web.Html.TreeBuilderBody.inc}
{$I Web.Html.TreeBuilderTables.inc}
{$I Web.Html.TreeBuilderSelect.inc}
{$I Web.Html.TreeBuilderAfter.inc}
{$I Web.Html.TreeBuilderForeign.inc}

end.

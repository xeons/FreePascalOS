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
  The XML parser for documents (XML 1.0 with Namespaces, as the HTML
  Standard's XML syntax asks of a browser): UTF-8 text into the nodes of
  an empty TDocument - elements with their namespaces and prefixes,
  attributes (xmlns ones too, in the XMLNS namespace), text, CDATA
  sections, comments, processing instructions and the document type
  (name, public and system identifiers; the internal subset's general
  entities are expanded, to a limited depth and size).

  It is a conforming non-validating parser in what it refuses: a
  document that is not well-formed (a mismatched or missing end tag, an
  unbound prefix, a repeated attribute, '<' in an attribute value, an
  undefined entity, text or a second element outside the root, no root)
  fails with a message and a line number, and the caller shows the
  parser error document browsers show.

  The open elements are a stack rather than recursion, so the parser
  can stop after a script element's end tag (OnScriptEnd: the HTML
  Standard's "pause" for a pending parsing-blocking script) and go on
  where it was (Resume): a document of a browsing context (XHTML) runs
  its scripts as the tree grows.
}
unit Web.Xml.Parser;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Dom;

type
  { The parser met the end tag of a script element (HTML namespace):
    True when a parsing-blocking script is now pending, and the parser
    pauses until Resume. }
  TXmlScriptEndEvent = function(Script: TElement): Boolean of object;

  EXmlSyntax = class(Exception);

  TXmlEntity = record
    Name, Value: string;
  end;

  TXmlNamespaceBinding = record
    Prefix, Uri: string;
    Depth: Integer;
  end;

  TXmlOpenElement = record
    Element: TElement;
    QualifiedName: string;
  end;

  { A document's parser that can pause after a script's end tag (the
    HTML Standard's XML parser in a browsing context): Run parses until
    the end, a pause or an error. }
  TXmlDocumentParser = class
  private
    FDocument: TDocument;
    FText: string;
    FPosition, FLength: Integer;
    FEntities: array of TXmlEntity;
    FBindings: array of TXmlNamespaceBinding;
    FBindingCount: Integer;
    FExpanded: Int64;
    { The elements whose end tags are still to come, the root first. }
    FOpen: array of TXmlOpenElement;
    FOpenCount: Integer;
    FHaveRoot: Boolean;
    FEnded, FPaused, FFailed: Boolean;
    FError: string;
    FOnScriptEnd: TXmlScriptEndEvent;
    procedure Fail(const Message: string);
    function AtEnd: Boolean; inline;
    function Peek: Char; inline;
    function StartsWith(const Prefix: string): Boolean;
    procedure SkipWhitespace;
    function ReadUntil(const Marker, What: string): string;
    function ReadName: string;
    procedure Expect(Character: Char);
    function DecodeReferences(const Raw: string; Depth: Integer): string;
    function ReadQuoted: string;
    function LookUpNamespace(const Prefix: string; out Uri: string): Boolean;
    procedure PushBinding(const Prefix, Uri: string; Depth: Integer);
    procedure PopBindings(Depth: Integer);
    procedure ParseDoctype;
    procedure ReadEntityDeclarations(const Subset: string);
    procedure ParseProcessingInstruction(Parent: TNode);
    procedure ParseComment(Parent: TNode);
    procedure ParseStartTag(Parent: TNode);
    procedure ParseEndTag;
    procedure ElementEnded(Element: TElement);
    procedure StepOutsideRoot;
    procedure StepInContent;
    function LineNumber: Integer;
  public
    constructor Create(Document: TDocument; const Text: string);
    { Parses on until the end, a pause (OnScriptEnd) or an error. }
    procedure Run;
    { Goes on after a pause. }
    procedure Resume;
    property Ended: Boolean read FEnded;
    property Paused: Boolean read FPaused;
    { Not well-formed: Error says why (with the line). }
    property Failed: Boolean read FFailed;
    property Error: string read FError;
    { Set before Run: script elements are then marked parser-inserted
      and reported at their end tags. }
    property OnScriptEnd: TXmlScriptEndEvent read FOnScriptEnd write FOnScriptEnd;
  end;

{ Parses Text into Document (which has no children yet). False when the
  text is not well-formed: Error says why, and Document may hold part
  of the tree. }
function ParseXmlInto(Document: TDocument; const Text: string; out Error: string): Boolean;
{ An XML document from Text, or the parser error document (a
  <parsererror> in Mozilla's namespace with the message) when it is not
  well-formed. ContentType: the document's content type. }
function ParseXmlDocument(const Text, ContentType, Url: string): TDocument;
{ Document's content replaced by the parser error document for Error. }
procedure ShowXmlParserError(Document: TDocument; const Error: string);

implementation

uses
  Classes,
  Web.Atoms;

const
  XmlNamespaceUri = 'http://www.w3.org/XML/1998/namespace';
  XmlnsNamespaceUri = 'http://www.w3.org/2000/xmlns/';
  ParserErrorNamespace = 'http://www.mozilla.org/newlayout/xml/parsererror.xml';
  MaximumDepth = 1024;
  MaximumEntityDepth = 8;
  MaximumEntityExpansion = 4 * 1024 * 1024;

type
  TRawAttribute = record
    QualifiedName, Value: string;
  end;


function IsNameStart(Character: Char): Boolean; inline;
begin
  Result := (Character in ['A'..'Z', 'a'..'z', '_', ':']) or (Ord(Character) >= $80);
end;

function IsNameCharacter(Character: Char): Boolean; inline;
begin
  Result := IsNameStart(Character) or (Character in ['0'..'9', '-', '.']);
end;

function IsSpace(Character: Char): Boolean; inline;
begin
  Result := Character in [' ', #9, #10, #13];
end;

function CodePointToUtf8(CodePoint: LongWord): string;
begin
  if CodePoint < $80 then
    Result := Chr(CodePoint)
  else if CodePoint < $800 then
    Result := Chr($C0 or (CodePoint shr 6)) + Chr($80 or (CodePoint and $3F))
  else if CodePoint < $10000 then
    Result := Chr($E0 or (CodePoint shr 12)) + Chr($80 or ((CodePoint shr 6) and $3F)) +
      Chr($80 or (CodePoint and $3F))
  else
    Result := Chr($F0 or (CodePoint shr 18)) + Chr($80 or ((CodePoint shr 12) and $3F)) +
      Chr($80 or ((CodePoint shr 6) and $3F)) + Chr($80 or (CodePoint and $3F));
end;

{ A character XML allows (Char production). }
function IsXmlCharacter(CodePoint: LongWord): Boolean;
begin
  Result := (CodePoint = 9) or (CodePoint = 10) or (CodePoint = 13) or ((CodePoint >= $20) and (CodePoint <= $D7FF)) or
    ((CodePoint >= $E000) and (CodePoint <= $FFFD)) or ((CodePoint >= $10000) and (CodePoint <= $10FFFF));
end;

procedure SplitQualifiedName(const QualifiedName: string; out Prefix, LocalName: string);
var
  Colon: Integer;
begin
  Colon := Pos(':', QualifiedName);
  if Colon > 0 then
  begin
    Prefix := Copy(QualifiedName, 1, Colon - 1);
    LocalName := Copy(QualifiedName, Colon + 1, MaxInt);
  end
  else
  begin
    Prefix := '';
    LocalName := QualifiedName;
  end;
end;

{ Line breaks normalized (CR LF and CR are LF), as XML 2.11 asks. }
function NormalizeLineBreaks(const Text: string): string;
begin
  if Pos(#13, Text) = 0 then
    Exit(Text);
  Result := StringReplace(Text, #13#10, #10, [rfReplaceAll]);
  Result := StringReplace(Result, #13, #10, [rfReplaceAll]);
end;

constructor TXmlDocumentParser.Create(Document: TDocument; const Text: string);
begin
  inherited Create;
  FDocument := Document;
  FText := NormalizeLineBreaks(Text);
  if (Length(FText) >= 3) and (FText[1] = #$EF) and (FText[2] = #$BB) and (FText[3] = #$BF) then
    Delete(FText, 1, 3);
  FLength := Length(FText);
  FPosition := 1;
  PushBinding('xml', XmlNamespaceUri, -1);
  PushBinding('xmlns', XmlnsNamespaceUri, -1);
end;

function TXmlDocumentParser.LineNumber: Integer;
var
  Index: Integer;
begin
  Result := 1;
  for Index := 1 to FPosition - 1 do
    if (Index <= FLength) and (FText[Index] = #10) then
      Inc(Result);
end;

procedure TXmlDocumentParser.Fail(const Message: string);
begin
  raise EXmlSyntax.Create(Message + ' (line ' + IntToStr(LineNumber) + ')');
end;

function TXmlDocumentParser.AtEnd: Boolean;
begin
  Result := FPosition > FLength;
end;

function TXmlDocumentParser.Peek: Char;
begin
  if FPosition <= FLength then
    Result := FText[FPosition]
  else
    Result := #0;
end;

function TXmlDocumentParser.StartsWith(const Prefix: string): Boolean;
begin
  Result := (FPosition + Length(Prefix) - 1 <= FLength) and
    (CompareByte(FText[FPosition], Prefix[1], Length(Prefix)) = 0);
end;

procedure TXmlDocumentParser.SkipWhitespace;
begin
  while (FPosition <= FLength) and IsSpace(FText[FPosition]) do
    Inc(FPosition);
end;

{ The text up to Marker; the position moves past it. }
function TXmlDocumentParser.ReadUntil(const Marker, What: string): string;
var
  Found: Integer;
begin
  Found := Pos(Marker, FText, FPosition);
  if Found = 0 then
    Fail('unclosed ' + What);
  Result := Copy(FText, FPosition, Found - FPosition);
  FPosition := Found + Length(Marker);
end;

function TXmlDocumentParser.ReadName: string;
var
  Start: Integer;
begin
  Start := FPosition;
  if (FPosition <= FLength) and IsNameStart(FText[FPosition]) then
    while (FPosition <= FLength) and IsNameCharacter(FText[FPosition]) do
      Inc(FPosition);
  Result := Copy(FText, Start, FPosition - Start);
end;

procedure TXmlDocumentParser.Expect(Character: Char);
begin
  if Peek <> Character then
    Fail('expected "' + Character + '"');
  Inc(FPosition);
end;

function TXmlDocumentParser.DecodeReferences(const Raw: string; Depth: Integer): string;
var
  Index, Close, Code, Entity: Integer;
  Name, Expansion: string;
  CodePoint: LongWord;
begin
  if Pos('&', Raw) = 0 then
    Exit(Raw);
  Result := '';
  Index := 1;
  while Index <= Length(Raw) do
  begin
    if Raw[Index] <> '&' then
    begin
      Close := Pos('&', Raw, Index);
      if Close = 0 then
        Close := Length(Raw) + 1;
      Result := Result + Copy(Raw, Index, Close - Index);
      Index := Close;
      Continue;
    end;
    Close := Pos(';', Raw, Index);
    if Close = 0 then
      Fail('an unterminated reference');
    Name := Copy(Raw, Index + 1, Close - Index - 1);
    Index := Close + 1;
    if (Name <> '') and (Name[1] = '#') then
    begin
      if (Length(Name) > 1) and (Name[2] = 'x') then
        Val('$' + Copy(Name, 3, MaxInt), CodePoint, Code)
      else
        Val(Copy(Name, 2, MaxInt), CodePoint, Code);
      if (Code <> 0) or (Length(Name) < 2) or not IsXmlCharacter(CodePoint) then
        Fail('a bad character reference &' + Name + ';');
      Result := Result + CodePointToUtf8(CodePoint);
    end
    else if Name = 'lt' then
      Result := Result + '<'
    else if Name = 'gt' then
      Result := Result + '>'
    else if Name = 'amp' then
      Result := Result + '&'
    else if Name = 'quot' then
      Result := Result + '"'
    else if Name = 'apos' then
      Result := Result + ''''
    else
    begin
      Entity := -1;
      for Code := 0 to High(FEntities) do
        if FEntities[Code].Name = Name then
        begin
          Entity := Code;
          Break;
        end;
      if Entity < 0 then
        Fail('an undefined entity &' + Name + ';');
      if Depth >= MaximumEntityDepth then
        Fail('entities nested too deeply');
      Expansion := DecodeReferences(FEntities[Entity].Value, Depth + 1);
      Inc(FExpanded, Length(Expansion));
      if FExpanded > MaximumEntityExpansion then
        Fail('entities expand too far');
      Result := Result + Expansion;
    end;
  end;
end;

function TXmlDocumentParser.ReadQuoted: string;
var
  Quote: Char;
  Raw: string;
  Index: Integer;
begin
  Quote := Peek;
  if not (Quote in ['"', '''']) then
    Fail('an attribute value without quotes');
  Inc(FPosition);
  Raw := ReadUntil(Quote, 'attribute value');
  if Pos('<', Raw) > 0 then
    Fail('"<" in an attribute value');
  { Attribute-value normalization: white space characters are spaces. }
  for Index := 1 to Length(Raw) do
    if Raw[Index] in [#9, #10] then
      Raw[Index] := ' ';
  Result := DecodeReferences(Raw, 0);
end;

function TXmlDocumentParser.LookUpNamespace(const Prefix: string; out Uri: string): Boolean;
var
  Index: Integer;
begin
  for Index := FBindingCount - 1 downto 0 do
    if FBindings[Index].Prefix = Prefix then
    begin
      Uri := FBindings[Index].Uri;
      Exit(True);
    end;
  Uri := '';
  Result := False;
end;

procedure TXmlDocumentParser.PushBinding(const Prefix, Uri: string; Depth: Integer);
begin
  if FBindingCount = Length(FBindings) then
    SetLength(FBindings, 2 * FBindingCount + 8);
  FBindings[FBindingCount].Prefix := Prefix;
  FBindings[FBindingCount].Uri := Uri;
  FBindings[FBindingCount].Depth := Depth;
  Inc(FBindingCount);
end;

procedure TXmlDocumentParser.PopBindings(Depth: Integer);
begin
  while (FBindingCount > 0) and (FBindings[FBindingCount - 1].Depth >= Depth) do
    Dec(FBindingCount);
end;

procedure TXmlDocumentParser.ReadEntityDeclarations(const Subset: string);
var
  Index, Start, ValueStart: Integer;
  Name: string;
  Quote: Char;
begin
  Index := Pos('<!ENTITY', Subset);
  while Index > 0 do
  begin
    Inc(Index, 8);
    while (Index <= Length(Subset)) and IsSpace(Subset[Index]) do
      Inc(Index);
    if (Index <= Length(Subset)) and (Subset[Index] = '%') then
    begin
      Index := Pos('<!ENTITY', Subset, Index);
      Continue;
    end;
    Start := Index;
    while (Index <= Length(Subset)) and IsNameCharacter(Subset[Index]) do
      Inc(Index);
    Name := Copy(Subset, Start, Index - Start);
    while (Index <= Length(Subset)) and IsSpace(Subset[Index]) do
      Inc(Index);
    if (Name <> '') and (Index <= Length(Subset)) and (Subset[Index] in ['"', '''']) then
    begin
      Quote := Subset[Index];
      ValueStart := Index + 1;
      Index := ValueStart;
      while (Index <= Length(Subset)) and (Subset[Index] <> Quote) do
        Inc(Index);
      SetLength(FEntities, Length(FEntities) + 1);
      FEntities[High(FEntities)].Name := Name;
      FEntities[High(FEntities)].Value := Copy(Subset, ValueStart, Index - ValueStart);
    end;
    Index := Pos('<!ENTITY', Subset, Index);
  end;
end;

{ At "<!DOCTYPE". }
procedure TXmlDocumentParser.ParseDoctype;
var
  Name, PublicId, SystemId: string;
  Start: Integer;
  Quote: Char;
begin
  Inc(FPosition, 9);
  SkipWhitespace;
  Name := ReadName;
  if Name = '' then
    Fail('a document type without a name');
  PublicId := '';
  SystemId := '';
  SkipWhitespace;
  if StartsWith('PUBLIC') then
  begin
    Inc(FPosition, 6);
    SkipWhitespace;
    PublicId := ReadQuoted;
    SkipWhitespace;
    if Peek in ['"', ''''] then
      SystemId := ReadQuoted;
  end
  else if StartsWith('SYSTEM') then
  begin
    Inc(FPosition, 6);
    SkipWhitespace;
    SystemId := ReadQuoted;
  end;
  SkipWhitespace;
  if Peek = '[' then
  begin
    Inc(FPosition);
    Start := FPosition;
    while not AtEnd and (Peek <> ']') do
    begin
      if Peek in ['"', ''''] then
      begin
        Quote := Peek;
        Inc(FPosition);
        while not AtEnd and (Peek <> Quote) do
          Inc(FPosition);
      end;
      Inc(FPosition);
    end;
    if AtEnd then
      Fail('an unclosed internal subset');
    ReadEntityDeclarations(Copy(FText, Start, FPosition - Start));
    Inc(FPosition);
    SkipWhitespace;
  end;
  Expect('>');
  FDocument.AppendChild(FDocument.NewDocumentType(Name, PublicId, SystemId));
end;

{ At "<?". The XML declaration is not a node. }
procedure TXmlDocumentParser.ParseProcessingInstruction(Parent: TNode);
var
  Target, Data: string;
begin
  Inc(FPosition, 2);
  Target := ReadName;
  if Target = '' then
    Fail('a processing instruction without a target');
  if not AtEnd and not IsSpace(Peek) and not StartsWith('?>') then
    Fail('a bad processing instruction target');
  SkipWhitespace;
  Data := ReadUntil('?>', 'processing instruction');
  if LowerCase(Target) = 'xml' then
  begin
    if (Parent <> FDocument) or (FDocument.FirstChild <> nil) or (Target <> 'xml') then
      Fail('an XML declaration not at the start');
    Exit;
  end;
  Parent.AppendChild(FDocument.CreateProcessingInstruction(Target, Data));
end;

{ At "<!--". }
procedure TXmlDocumentParser.ParseComment(Parent: TNode);
var
  Data: string;
begin
  Inc(FPosition, 4);
  Data := ReadUntil('-->', 'comment');
  if (Pos('--', Data) > 0) or ((Data <> '') and (Data[Length(Data)] = '-')) then
    Fail('"--" in a comment');
  Parent.AppendChild(FDocument.NewComment(Data));
end;

{ At '<' of a start tag: the element appended to Parent and, unless it
  closes itself, opened. }
procedure TXmlDocumentParser.ParseStartTag(Parent: TNode);
var
  QualifiedName, Name, Value, Prefix, LocalName, Uri: string;
  Raw: array of TRawAttribute;
  Element: TElement;
  Index, Depth: Integer;
  SelfClosing: Boolean;
begin
  Depth := FOpenCount;
  if Depth > MaximumDepth then
    Fail('elements nested too deeply');
  Inc(FPosition);
  QualifiedName := ReadName;
  if QualifiedName = '' then
    Fail('a bad start tag');
  Raw := nil;
  SelfClosing := False;
  repeat
    if StartsWith('/>') then
    begin
      Inc(FPosition, 2);
      SelfClosing := True;
      Break;
    end;
    if Peek = '>' then
    begin
      Inc(FPosition);
      Break;
    end;
    if not IsSpace(Peek) then
      Fail('a bad start tag <' + QualifiedName + '>');
    SkipWhitespace;
    if StartsWith('/>') or (Peek = '>') then
      Continue;
    Name := ReadName;
    if Name = '' then
      Fail('a bad attribute in <' + QualifiedName + '>');
    SkipWhitespace;
    Expect('=');
    SkipWhitespace;
    Value := ReadQuoted;
    for Index := 0 to High(Raw) do
      if Raw[Index].QualifiedName = Name then
        Fail('the attribute ' + Name + ' twice');
    SetLength(Raw, Length(Raw) + 1);
    Raw[High(Raw)].QualifiedName := Name;
    Raw[High(Raw)].Value := Value;
    if Name = 'xmlns' then
      PushBinding('', Value, Depth)
    else if Copy(Name, 1, 6) = 'xmlns:' then
    begin
      if Value = '' then
        Fail('an empty namespace for the prefix ' + Copy(Name, 7, MaxInt));
      PushBinding(Copy(Name, 7, MaxInt), Value, Depth);
    end;
  until False;
  SplitQualifiedName(QualifiedName, Prefix, LocalName);
  if not LookUpNamespace(Prefix, Uri) and (Prefix <> '') then
    Fail('the unbound prefix ' + Prefix);
  try
    Element := FDocument.CreateElementNS(Uri, QualifiedName);
  except
    on Error: Exception do
      Fail('a bad element name ' + QualifiedName);
  end;
  { A script the parser inserts waits for its end tag. }
  if Assigned(FOnScriptEnd) and Element.IsHtmlElement(AtomScript) then
    Element.ElementState := Element.ElementState or ElementStateParserInserted;
  for Index := 0 to High(Raw) do
  begin
    SplitQualifiedName(Raw[Index].QualifiedName, Prefix, LocalName);
    if (Raw[Index].QualifiedName = 'xmlns') or (Prefix = 'xmlns') then
      Uri := XmlnsNamespaceUri
    else if Prefix = '' then
      Uri := ''
    else if not LookUpNamespace(Prefix, Uri) then
      Fail('the unbound prefix ' + Prefix);
    try
      Element.SetAttributeNS(Uri, Raw[Index].QualifiedName, Raw[Index].Value);
    except
      on Error: Exception do
        Fail('a bad attribute ' + Raw[Index].QualifiedName);
    end;
  end;
  Parent.AppendChild(Element);
  if Parent = FDocument then
    FHaveRoot := True;
  if SelfClosing then
  begin
    PopBindings(Depth);
    ElementEnded(Element);
    Exit;
  end;
  if FOpenCount >= Length(FOpen) then
    SetLength(FOpen, FOpenCount * 2 + 16);
  FOpen[FOpenCount].Element := Element;
  FOpen[FOpenCount].QualifiedName := QualifiedName;
  Inc(FOpenCount);
end;

{ At "</": the end tag of the innermost open element. }
procedure TXmlDocumentParser.ParseEndTag;
var
  Name: string;
  Element: TElement;
begin
  Inc(FPosition, 2);
  Name := ReadName;
  if Name <> FOpen[FOpenCount - 1].QualifiedName then
    Fail('the end tag </' + Name + '> where </' + FOpen[FOpenCount - 1].QualifiedName + '> belongs');
  SkipWhitespace;
  Expect('>');
  Dec(FOpenCount);
  Element := FOpen[FOpenCount].Element;
  FOpen[FOpenCount].Element := nil;
  FOpen[FOpenCount].QualifiedName := '';
  PopBindings(FOpenCount);
  ElementEnded(Element);
end;

{ A script's end: the host prepares it, and the parser pauses while a
  parsing-blocking script is pending. }
procedure TXmlDocumentParser.ElementEnded(Element: TElement);
begin
  if Assigned(FOnScriptEnd) and Element.IsHtmlElement(AtomScript) then
    if FOnScriptEnd(Element) then
      FPaused := True;
end;

{ One construct of an open element's content. }
procedure TXmlDocumentParser.StepInContent;
var
  Start, Close: Integer;
  Raw: string;
  Element: TElement;
begin
  Element := FOpen[FOpenCount - 1].Element;
  if AtEnd then
    Fail('no end tag for <' + FOpen[FOpenCount - 1].QualifiedName + '>');
  if Peek <> '<' then
  begin
    Start := FPosition;
    Close := Pos('<', FText, FPosition);
    if Close = 0 then
      Close := FLength + 1;
    FPosition := Close;
    Raw := Copy(FText, Start, Close - Start);
    if Pos(']]>', Raw) > 0 then
      Fail('"]]>" in text');
    Element.AppendChild(FDocument.NewText(DecodeReferences(Raw, 0)));
  end
  else if StartsWith('</') then
    ParseEndTag
  else if StartsWith('<!--') then
    ParseComment(Element)
  else if StartsWith('<![CDATA[') then
  begin
    Inc(FPosition, 9);
    Element.AppendChild(FDocument.CreateCDataSection(ReadUntil(']]>', 'CDATA section')));
  end
  else if StartsWith('<?') then
    ParseProcessingInstruction(Element)
  else if StartsWith('<!') then
    Fail('a declaration inside an element')
  else
    ParseStartTag(Element);
end;

{ One construct before or after the root element. }
procedure TXmlDocumentParser.StepOutsideRoot;
begin
  SkipWhitespace;
  if AtEnd then
  begin
    if not FHaveRoot then
      Fail('no root element');
    FEnded := True;
  end
  else if StartsWith('<?') then
    ParseProcessingInstruction(FDocument)
  else if StartsWith('<!--') then
    ParseComment(FDocument)
  else if StartsWith('<!DOCTYPE') then
  begin
    if FHaveRoot then
      Fail('a document type after the root');
    ParseDoctype;
  end
  else if (Peek = '<') and (FPosition < FLength) and IsNameStart(FText[FPosition + 1]) then
  begin
    if FHaveRoot then
      Fail('a second root element');
    ParseStartTag(FDocument);
  end
  else
    Fail('text outside the root element');
end;

procedure TXmlDocumentParser.Run;
begin
  try
    while not (FEnded or FPaused or FFailed) do
      if FOpenCount > 0 then
        StepInContent
      else
        StepOutsideRoot;
  except
    on Failure: EXmlSyntax do
    begin
      FFailed := True;
      FEnded := True;
      FError := Failure.Message;
    end;
  end;
end;

procedure TXmlDocumentParser.Resume;
begin
  if not FPaused then
    Exit;
  FPaused := False;
  Run;
end;

function ParseXmlInto(Document: TDocument; const Text: string; out Error: string): Boolean;
var
  Parser: TXmlDocumentParser;
begin
  Parser := TXmlDocumentParser.Create(Document, Text);
  try
    Parser.Run;
    Error := Parser.Error;
    Result := not Parser.Failed;
  finally
    Parser.Free;
  end;
end;

procedure ShowXmlParserError(Document: TDocument; const Error: string);
var
  Root: TElement;
begin
  Document.ReplaceChildren([]);
  Root := Document.CreateElementNS(ParserErrorNamespace, 'parsererror');
  Root.AppendChild(Document.CreateTextNode('XML Parsing Error: ' + Error));
  Document.AppendChild(Root);
end;

function ParseXmlDocument(const Text, ContentType, Url: string): TDocument;
var
  Error: string;
begin
  Result := TDocument.CreateDocument(False);
  Result.IsXmlDocumentObject := True;
  Result.ContentType := ContentType;
  Result.Url := Url;
  if not ParseXmlInto(Result, Text, Error) then
    ShowXmlParserError(Result, Error);
end;

end.

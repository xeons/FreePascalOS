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
  The XML parser for SVG files: UTF-8 text (a byte order mark is
  skipped; UTF-16 files are converted) into a tree of TSvgNode.

  What it reads: the XML declaration and processing instructions
  (skipped), comments, CDATA sections, a document type declaration
  whose internal subset may declare general entities (<!ENTITY name
  "value">, as Illustrator writes them; expanded in attribute values and
  text, to a limited depth and size), elements with attributes in
  single or double quotes, the predefined and numeric character
  references, and namespaces: xmlns and xmlns:prefix declarations in
  scope, prefixed element and attribute names resolved through them.
  An element without a namespace at the root is taken as SVG (lenient,
  for files that forget xmlns).

  Malformed input ends the tree where it went wrong, keeping what came
  before (as browsers show a broken SVG up to its error); a document
  with no root element raises ESvgError.
}
unit Svg.Xml;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Svg.Nodes;

type
  ESvgError = class(Exception);

{ The root element of the document in Text (the caller owns the tree). }
function ParseSvgXml(const Text: string): TSvgNode;
{ Bytes as UTF-8 text: a UTF-8 byte order mark dropped, UTF-16 (by its
  mark) converted. }
function SvgBytesToText(const Data: TBytes): string;

implementation

const
  MaximumDepth = 512;
  MaximumEntityDepth = 8;
  { Expanded entity text a document may produce in total. }
  MaximumEntityExpansion = 4 * 1024 * 1024;

type
  TEntity = record
    Name: string;
    Value: string;
  end;

  TNamespaceBinding = record
    Prefix: string;
    Uri: string;
    Depth: Integer;
  end;

  TPendingAttribute = record
    QualifiedName: string;
    Value: string;
  end;

  TXmlParser = class
  private
    FText: string;
    FPosition: Integer;
    FLength: Integer;
    FEntities: array of TEntity;
    FBindings: array of TNamespaceBinding;
    FBindingCount: Integer;
    FExpanded: Int64;
    FRoot: TSvgNode;
    function AtEnd: Boolean; inline;
    function Peek: Char; inline;
    function StartsWith(const Prefix: string): Boolean;
    procedure SkipWhitespace;
    function SkipPast(const Marker: string): Boolean;
    function ReadName: string;
    procedure SkipDoctype;
    procedure ReadEntityDeclarations(const Subset: string);
    function FindEntity(const Name: string): Integer;
    function DecodeReferences(const Raw: string; Depth: Integer): string;
    function ReadQuoted(out Value: string): Boolean;
    function LookUpNamespace(const Prefix: string): string;
    procedure PushBinding(const Prefix, Uri: string; Depth: Integer);
    procedure PopBindings(Depth: Integer);
    function ParseElement(Parent: TSvgNode; Depth: Integer): Boolean;
    procedure ParseContent(Element: TSvgNode; Depth: Integer);
  public
    constructor Create(const Text: string);
    function Parse: TSvgNode;
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
  if (CodePoint = 0) or (CodePoint > $10FFFF) or ((CodePoint >= $D800) and (CodePoint <= $DFFF)) then
    CodePoint := $FFFD;
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

function SvgBytesToText(const Data: TBytes): string;
var
  Index: Integer;
  BigEndian: Boolean;
  Unit1, Unit2: LongWord;
  CodePoint: LongWord;
  Builder: string;
begin
  Result := '';
  if Length(Data) = 0 then
    Exit;
  if (Length(Data) >= 2) and (((Data[0] = $FF) and (Data[1] = $FE)) or ((Data[0] = $FE) and (Data[1] = $FF))) then
  begin
    BigEndian := Data[0] = $FE;
    Builder := '';
    Index := 2;
    while Index + 1 < Length(Data) do
    begin
      if BigEndian then
        Unit1 := (LongWord(Data[Index]) shl 8) or Data[Index + 1]
      else
        Unit1 := (LongWord(Data[Index + 1]) shl 8) or Data[Index];
      Inc(Index, 2);
      CodePoint := Unit1;
      if (Unit1 >= $D800) and (Unit1 < $DC00) and (Index + 1 < Length(Data)) then
      begin
        if BigEndian then
          Unit2 := (LongWord(Data[Index]) shl 8) or Data[Index + 1]
        else
          Unit2 := (LongWord(Data[Index + 1]) shl 8) or Data[Index];
        if (Unit2 >= $DC00) and (Unit2 < $E000) then
        begin
          CodePoint := $10000 + ((Unit1 - $D800) shl 10) + (Unit2 - $DC00);
          Inc(Index, 2);
        end;
      end;
      Builder := Builder + CodePointToUtf8(CodePoint);
    end;
    Exit(Builder);
  end;
  SetLength(Result, Length(Data));
  Move(Data[0], Result[1], Length(Data));
  if (Length(Result) >= 3) and (Result[1] = #$EF) and (Result[2] = #$BB) and (Result[3] = #$BF) then
    Delete(Result, 1, 3);
end;

constructor TXmlParser.Create(const Text: string);
begin
  inherited Create;
  FText := Text;
  FLength := Length(Text);
  FPosition := 1;
  PushBinding('xml', XmlNamespace, -1);
  PushBinding('xmlns', 'http://www.w3.org/2000/xmlns/', -1);
end;

function TXmlParser.AtEnd: Boolean;
begin
  Result := FPosition > FLength;
end;

function TXmlParser.Peek: Char;
begin
  if FPosition <= FLength then
    Result := FText[FPosition]
  else
    Result := #0;
end;

function TXmlParser.StartsWith(const Prefix: string): Boolean;
begin
  Result := (FPosition + Length(Prefix) - 1 <= FLength) and
    (CompareByte(FText[FPosition], Prefix[1], Length(Prefix)) = 0);
end;

procedure TXmlParser.SkipWhitespace;
begin
  while (FPosition <= FLength) and IsSpace(FText[FPosition]) do
    Inc(FPosition);
end;

function TXmlParser.SkipPast(const Marker: string): Boolean;
var
  Found: Integer;
begin
  Found := Pos(Marker, FText, FPosition);
  if Found = 0 then
  begin
    FPosition := FLength + 1;
    Exit(False);
  end;
  FPosition := Found + Length(Marker);
  Result := True;
end;

function TXmlParser.ReadName: string;
var
  Start: Integer;
begin
  Start := FPosition;
  if (FPosition <= FLength) and IsNameStart(FText[FPosition]) then
    while (FPosition <= FLength) and IsNameCharacter(FText[FPosition]) do
      Inc(FPosition);
  Result := Copy(FText, Start, FPosition - Start);
end;

procedure TXmlParser.ReadEntityDeclarations(const Subset: string);
var
  Index: Integer;
  Start: Integer;
  Name: string;
  Quote: Char;
  ValueStart: Integer;
begin
  Index := Pos('<!ENTITY', Subset);
  while Index > 0 do
  begin
    Inc(Index, 8);
    while (Index <= Length(Subset)) and IsSpace(Subset[Index]) do
      Inc(Index);
    { Parameter entities (<!ENTITY % name ...>) are not expanded. }
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
      if FindEntity(Name) < 0 then
      begin
        SetLength(FEntities, Length(FEntities) + 1);
        FEntities[High(FEntities)].Name := Name;
        FEntities[High(FEntities)].Value := Copy(Subset, ValueStart, Index - ValueStart);
      end;
    end;
    Index := Pos('<!ENTITY', Subset, Index);
  end;
end;

procedure TXmlParser.SkipDoctype;
var
  Start: Integer;
  Quote: Char;
begin
  { At "<!DOCTYPE": up to its '>', past quoted strings and the internal
    subset in brackets. }
  Inc(FPosition, 9);
  while not AtEnd do
  begin
    case Peek of
      '"', '''':
        begin
          Quote := Peek;
          Inc(FPosition);
          while not AtEnd and (Peek <> Quote) do
            Inc(FPosition);
          Inc(FPosition);
        end;
      '[':
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
          ReadEntityDeclarations(Copy(FText, Start, FPosition - Start));
          Inc(FPosition);
        end;
      '>':
        begin
          Inc(FPosition);
          Exit;
        end;
      else
        Inc(FPosition);
    end;
  end;
end;

function TXmlParser.FindEntity(const Name: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FEntities) do
    if FEntities[Index].Name = Name then
      Exit(Index);
  Result := -1;
end;

function TXmlParser.DecodeReferences(const Raw: string; Depth: Integer): string;
var
  Index: Integer;
  Close: Integer;
  Name: string;
  CodePoint: LongWord;
  Code: Integer;
  Entity: Integer;
  Expansion: string;
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
    if (Close = 0) or (Close - Index > 64) then
    begin
      Result := Result + '&';
      Inc(Index);
      Continue;
    end;
    Name := Copy(Raw, Index + 1, Close - Index - 1);
    Index := Close + 1;
    if (Name <> '') and (Name[1] = '#') then
    begin
      if (Length(Name) > 1) and (Name[2] in ['x', 'X']) then
        Val('$' + Copy(Name, 3, Length(Name)), CodePoint, Code)
      else
        Val(Copy(Name, 2, Length(Name)), CodePoint, Code);
      if Code = 0 then
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
      Entity := FindEntity(Name);
      if (Entity >= 0) and (Depth < MaximumEntityDepth) then
      begin
        Expansion := DecodeReferences(FEntities[Entity].Value, Depth + 1);
        Inc(FExpanded, Length(Expansion));
        if FExpanded <= MaximumEntityExpansion then
          Result := Result + Expansion;
      end;
    end;
  end;
end;

function TXmlParser.ReadQuoted(out Value: string): Boolean;
var
  Quote: Char;
  Start: Integer;
begin
  Value := '';
  Quote := Peek;
  if not (Quote in ['"', '''']) then
    Exit(False);
  Inc(FPosition);
  Start := FPosition;
  while not AtEnd and (Peek <> Quote) do
    Inc(FPosition);
  if AtEnd then
    Exit(False);
  Value := DecodeReferences(Copy(FText, Start, FPosition - Start), 0);
  Inc(FPosition);
  Result := True;
end;

function TXmlParser.LookUpNamespace(const Prefix: string): string;
var
  Index: Integer;
begin
  for Index := FBindingCount - 1 downto 0 do
    if FBindings[Index].Prefix = Prefix then
      Exit(FBindings[Index].Uri);
  Result := '';
end;

procedure TXmlParser.PushBinding(const Prefix, Uri: string; Depth: Integer);
begin
  if FBindingCount = Length(FBindings) then
    SetLength(FBindings, 2 * FBindingCount + 8);
  FBindings[FBindingCount].Prefix := Prefix;
  FBindings[FBindingCount].Uri := Uri;
  FBindings[FBindingCount].Depth := Depth;
  Inc(FBindingCount);
end;

procedure TXmlParser.PopBindings(Depth: Integer);
begin
  while (FBindingCount > 0) and (FBindings[FBindingCount - 1].Depth >= Depth) do
    Dec(FBindingCount);
end;

procedure SplitQualifiedName(const QualifiedName: string; out Prefix, LocalName: string);
var
  Colon: Integer;
begin
  Colon := Pos(':', QualifiedName);
  if Colon > 0 then
  begin
    Prefix := Copy(QualifiedName, 1, Colon - 1);
    LocalName := Copy(QualifiedName, Colon + 1, Length(QualifiedName));
  end
  else
  begin
    Prefix := '';
    LocalName := QualifiedName;
  end;
end;

{ At '<' of a start tag. False when the input is broken. }
function TXmlParser.ParseElement(Parent: TSvgNode; Depth: Integer): Boolean;
var
  QualifiedName: string;
  Pending: array of TPendingAttribute;
  PendingCount: Integer;
  AttributeName: string;
  Value: string;
  Prefix, LocalName: string;
  NamespaceUri: string;
  Element: TSvgNode;
  Index: Integer;
  SelfClosing: Boolean;
begin
  Result := False;
  if Depth > MaximumDepth then
    Exit;
  Inc(FPosition);
  QualifiedName := ReadName;
  if QualifiedName = '' then
    Exit;
  Pending := nil;
  PendingCount := 0;
  SelfClosing := False;
  repeat
    SkipWhitespace;
    if AtEnd then
      Exit;
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
    AttributeName := ReadName;
    if AttributeName = '' then
      Exit;
    SkipWhitespace;
    if Peek <> '=' then
      Exit;
    Inc(FPosition);
    SkipWhitespace;
    if not ReadQuoted(Value) then
      Exit;
    if AttributeName = 'xmlns' then
      PushBinding('', Value, Depth)
    else if Copy(AttributeName, 1, 6) = 'xmlns:' then
      PushBinding(Copy(AttributeName, 7, Length(AttributeName)), Value, Depth)
    else
    begin
      if PendingCount = Length(Pending) then
        SetLength(Pending, 2 * PendingCount + 8);
      Pending[PendingCount].QualifiedName := AttributeName;
      Pending[PendingCount].Value := Value;
      Inc(PendingCount);
    end;
  until False;
  SplitQualifiedName(QualifiedName, Prefix, LocalName);
  NamespaceUri := LookUpNamespace(Prefix);
  if (NamespaceUri = '') and (Prefix = '') and ((Parent = nil) or (Parent.NamespaceUri = SvgNamespace)) then
    NamespaceUri := SvgNamespace;
  Element := TSvgNode.CreateElement(NamespaceUri, LocalName);
  for Index := 0 to PendingCount - 1 do
  begin
    SplitQualifiedName(Pending[Index].QualifiedName, Prefix, LocalName);
    if Prefix = '' then
      Element.SetAttribute('', LocalName, Pending[Index].Value)
    else
      Element.SetAttribute(LookUpNamespace(Prefix), LocalName, Pending[Index].Value);
  end;
  if Parent = nil then
    FRoot := Element
  else
    Parent.AppendChild(Element);
  if not SelfClosing then
    ParseContent(Element, Depth);
  PopBindings(Depth);
  Result := True;
end;

procedure TXmlParser.ParseContent(Element: TSvgNode; Depth: Integer);
var
  Start: Integer;
  Text: string;
  Close: Integer;
begin
  while not AtEnd do
  begin
    if Peek <> '<' then
    begin
      Start := FPosition;
      Close := Pos('<', FText, FPosition);
      if Close = 0 then
        Close := FLength + 1;
      FPosition := Close;
      Text := DecodeReferences(Copy(FText, Start, Close - Start), 0);
      if Text <> '' then
        Element.AppendChild(TSvgNode.CreateText(Text));
      Continue;
    end;
    if StartsWith('</') then
    begin
      Inc(FPosition, 2);
      ReadName;
      SkipWhitespace;
      if Peek = '>' then
        Inc(FPosition);
      { A mismatched end tag ends this element anyway. }
      Exit;
    end;
    if StartsWith('<!--') then
    begin
      SkipPast('-->');
      Continue;
    end;
    if StartsWith('<![CDATA[') then
    begin
      Start := FPosition + 9;
      Close := Pos(']]>', FText, Start);
      if Close = 0 then
        Close := FLength + 1;
      Element.AppendChild(TSvgNode.CreateText(Copy(FText, Start, Close - Start)));
      FPosition := Close + 3;
      Continue;
    end;
    if StartsWith('<?') then
    begin
      SkipPast('?>');
      Continue;
    end;
    if StartsWith('<!') then
    begin
      SkipPast('>');
      Continue;
    end;
    if not ParseElement(Element, Depth + 1) then
    begin
      FPosition := FLength + 1;
      Exit;
    end;
  end;
end;

function TXmlParser.Parse: TSvgNode;
begin
  FRoot := nil;
  while not AtEnd do
  begin
    SkipWhitespace;
    if AtEnd then
      Break;
    if StartsWith('<?') then
      SkipPast('?>')
    else if StartsWith('<!--') then
      SkipPast('-->')
    else if StartsWith('<!DOCTYPE') then
      SkipDoctype
    else if StartsWith('<!') then
      SkipPast('>')
    else if Peek = '<' then
    begin
      ParseElement(nil, 0);
      Break;
    end
    else
      Inc(FPosition);
  end;
  Result := FRoot;
  if Result = nil then
    raise ESvgError.Create('no root element');
end;

function ParseSvgXml(const Text: string): TSvgNode;
var
  Parser: TXmlParser;
begin
  Parser := TXmlParser.Create(Text);
  try
    Result := Parser.Parse;
  finally
    Parser.Free;
  end;
end;

end.

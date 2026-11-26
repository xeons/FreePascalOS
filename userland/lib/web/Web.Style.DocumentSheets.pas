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
  A document's style sheet objects, shared by styling (Web.Style.Sheets)
  and script (the CSSOM, Web.Bindings.StyleSheets), which see the same
  TCssStyleSheet: a rule script inserts is in the sheet the styler
  indexes.

  - The sheet of each <style> element, parsed from its text when first
    asked for (by script right after the element was inserted, or by
    the styler) and again when the text or media attribute changed; the
    old sheet goes then, as in the CSSOM.
  - The sheets of <link rel=stylesheet> elements, which the loader's
    resources own: they tell this object (SetLinkSheet).
  - Sheets script made (new CSSStyleSheet()), owned here, and the
    document's adoptedStyleSheets, which come after the others.

  Changes script makes are told to the listeners: a rule appended at
  the end of a sheet (which the style engine may index at once), or the
  sheets' contents otherwise changed (indexed again).
}
unit Web.Style.DocumentSheets;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom, Css.Stylesheets;

type
  TSheetChange = (scContentsChanged, scRuleAppended, scSheetsChanged);
  TSheetChangeListener = procedure(Change: TSheetChange; Sheet: TCssStyleSheet; Rule: TCssRule) of object;
  { A sheet made from a <style> element has @import rules to load. }
  TSheetParsedEvent = procedure(Sheet: TCssStyleSheet; Owner: TElement) of object;

  TOwnedSheet = record
    Owner: TElement;
    Sheet: TCssStyleSheet;
    { <style>: the text and media it was parsed from; owned here. }
    Source: string;
    Media: string;
    OwnedHere: Boolean;
  end;

  TCssStyleSheetList = array of TCssStyleSheet;

  TDocumentSheets = class(TDocumentObserver)
  private
    FDocument: TDocument;
    FSheets: array of TOwnedSheet;
    FConstructed: TCssStyleSheetList;
    FAdopted: TCssStyleSheetList;
    FListeners: array of TSheetChangeListener;
    { Sheets and rules taken out of use, freed once the style engine no
      longer refers to them (FreeRetired, after it indexed again). }
    FRetired: array of TObject;
    FOnSheetParsed: TSheetParsedEvent;
    function FindOwner(Element: TElement): Integer;
    procedure RemoveAt(Index: Integer);
    procedure RetireSheet(Sheet: TCssStyleSheet);
  public
    procedure Notify(Change: TSheetChange; Sheet: TCssStyleSheet; Rule: TCssRule);
    constructor Create(Document: TDocument);
    destructor Destroy; override;
    { The current sheet of a <style> element (parsed now if its text or
      media changed), nil for one not in the document. }
    function StyleElementSheet(Element: TElement): TCssStyleSheet;
    { A <link>'s sheet from the resources (not owned; nil removes it). }
    procedure SetLinkSheet(Element: TElement; Sheet: TCssStyleSheet);
    function LinkSheet(Element: TElement): TCssStyleSheet;
    { The element whose sheet Sheet is, nil if none (constructed, or an
      imported sheet). }
    function OwnerOf(Sheet: TCssStyleSheet): TElement;
    { A <style> element left the document: its sheet goes. }
    procedure ElementRemoved(Element: TElement);
    { new CSSStyleSheet(): a sheet kept until the document goes. }
    function NewConstructedSheet(const BaseUrl: string): TCssStyleSheet;
    function IsConstructed(Sheet: TCssStyleSheet): Boolean;
    procedure SetAdoptedSheets(const Sheets: TCssStyleSheetList);
    property AdoptedSheets: TCssStyleSheetList read FAdopted;
    { Script changed a sheet's rules. }
    procedure RuleAppended(Sheet: TCssStyleSheet; Rule: TCssRule);
    procedure ContentsChanged(Sheet: TCssStyleSheet);
    { A rule script removed: freed later (see FRetired). }
    procedure RetireRule(Rule: TCssRule);
    { Another object the engine may still refer to (a rule's old
      selectors). }
    procedure RetireObject(Item: TObject);
    { The style engine indexed the sheets again: what was retired goes. }
    procedure FreeRetired;
    procedure AddListener(Listener: TSheetChangeListener);
    procedure RemoveListener(Listener: TSheetChangeListener);
    { A <style> leaving the document takes its sheet with it. }
    procedure NodeDisconnected(Node: TNode); override;
    property Document: TDocument read FDocument;
    property OnSheetParsed: TSheetParsedEvent read FOnSheetParsed write FOnSheetParsed;
  end;

{ A shadow root's adoptedStyleSheets (the sheets are the document's
  constructed ones; the list is kept with the shadow root). Setting
  them tells the document's sheet listeners. }
function ShadowRootAdoptedSheets(Shadow: TShadowRoot): TCssStyleSheetList;
procedure SetShadowRootAdoptedSheets(Shadow: TShadowRoot; const Sheets: TCssStyleSheetList);

{ The document's sheets, made when first asked for (the document frees
  them). }
function DocumentSheetsOf(Document: TDocument): TDocumentSheets;
{ The document's sheets if made, nil otherwise. }
function ExistingDocumentSheets(Document: TDocument): TDocumentSheets;

implementation

uses
  SysUtils, Web.Atoms, Web.Profiling, Css.Parser, Css.MediaQueries;

type
  TShadowRootSheets = class
  public
    Adopted: TCssStyleSheetList;
  end;

function ShadowRootAdoptedSheets(Shadow: TShadowRoot): TCssStyleSheetList;
begin
  if Shadow.StyleSheets = nil then
    Result := nil
  else
    Result := TShadowRootSheets(Shadow.StyleSheets).Adopted;
end;

procedure SetShadowRootAdoptedSheets(Shadow: TShadowRoot; const Sheets: TCssStyleSheetList);
begin
  if Shadow.StyleSheets = nil then
    Shadow.StyleSheets := TShadowRootSheets.Create;
  TShadowRootSheets(Shadow.StyleSheets).Adopted := Copy(Sheets);
  DocumentSheetsOf(Shadow.NodeDocument).Notify(scSheetsChanged, nil, nil);
end;

function ExistingDocumentSheets(Document: TDocument): TDocumentSheets;
begin
  Result := TDocumentSheets(Document.StyleSheets);
end;

function DocumentSheetsOf(Document: TDocument): TDocumentSheets;
begin
  Result := TDocumentSheets(Document.StyleSheets);
  if Result = nil then
  begin
    Result := TDocumentSheets.Create(Document);
    Document.StyleSheets := Result;
  end;
end;

constructor TDocumentSheets.Create(Document: TDocument);
begin
  inherited Create;
  FDocument := Document;
  Document.AddObserver(Self);
end;

destructor TDocumentSheets.Destroy;
var
  Index: Integer;
begin
  FDocument.RemoveObserver(Self);
  for Index := 0 to High(FSheets) do
    if FSheets[Index].OwnedHere then
      FSheets[Index].Sheet.Free;
  for Index := 0 to High(FConstructed) do
    FConstructed[Index].Free;
  FreeRetired;
  inherited Destroy;
end;

function TDocumentSheets.FindOwner(Element: TElement): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FSheets) do
    if FSheets[Index].Owner = Element then
      Exit(Index);
  Result := -1;
end;

procedure TDocumentSheets.RetireSheet(Sheet: TCssStyleSheet);
begin
  if Sheet = nil then
    Exit;
  if (Sheet.HostData <> nil) and Assigned(CssHostDataFreed) then
    CssHostDataFreed(Sheet.HostData);
  Sheet.HostData := nil;
  SetLength(FRetired, Length(FRetired) + 1);
  FRetired[High(FRetired)] := Sheet;
end;

procedure TDocumentSheets.RetireRule(Rule: TCssRule);
begin
  { Its CSSOM object keeps answering until the rule is freed. }
  Rule.Parent := nil;
  SetRuleSheet(Rule, nil);
  SetLength(FRetired, Length(FRetired) + 1);
  FRetired[High(FRetired)] := Rule;
end;

procedure TDocumentSheets.RetireObject(Item: TObject);
begin
  SetLength(FRetired, Length(FRetired) + 1);
  FRetired[High(FRetired)] := Item;
end;

procedure TDocumentSheets.FreeRetired;
var
  Index: Integer;
begin
  for Index := 0 to High(FRetired) do
    FRetired[Index].Free;
  FRetired := nil;
end;

procedure TDocumentSheets.RemoveAt(Index: Integer);
begin
  if FSheets[Index].OwnedHere then
    RetireSheet(FSheets[Index].Sheet);
  FSheets[Index] := FSheets[High(FSheets)];
  SetLength(FSheets, Length(FSheets) - 1);
end;

procedure TDocumentSheets.Notify(Change: TSheetChange; Sheet: TCssStyleSheet; Rule: TCssRule);
var
  Index: Integer;
begin
  for Index := 0 to High(FListeners) do
    FListeners[Index](Change, Sheet, Rule);
end;

function TDocumentSheets.StyleElementSheet(Element: TElement): TCssStyleSheet;
var
  Index, Rule: Integer;
  Source, Media: string;
  HasImports: Boolean;
begin
  Result := nil;
  if not Element.IsConnected then
    Exit;
  Source := DescendantTextContent(Element);
  Media := Element.AttributeValueOf(AtomMedia);
  Index := FindOwner(Element);
  if Index >= 0 then
  begin
    if (FSheets[Index].Source = Source) and (FSheets[Index].Media = Media) then
      Exit(FSheets[Index].Sheet);
    RetireSheet(FSheets[Index].Sheet);
    FSheets[Index].Sheet := nil;
  end;
  EnterPhase(PhaseStyleSheetParse);
  try
    Result := ParseStyleSheet(Source, coAuthor, FDocument.Url);
  finally
    LeavePhase;
  end;
  if Trim(Media) <> '' then
    Result.Media := ParseMediaQueryText(Media);
  if Index < 0 then
  begin
    SetLength(FSheets, Length(FSheets) + 1);
    Index := High(FSheets);
    FSheets[Index].Owner := Element;
  end;
  FSheets[Index].Source := Source;
  FSheets[Index].Media := Media;
  FSheets[Index].Sheet := Result;
  FSheets[Index].OwnedHere := True;
  HasImports := False;
  for Rule := 0 to High(Result.Rules) do
    if Result.Rules[Rule].Kind = rkImport then
      HasImports := True;
  if HasImports and Assigned(FOnSheetParsed) then
    FOnSheetParsed(Result, Element);
end;

procedure TDocumentSheets.SetLinkSheet(Element: TElement; Sheet: TCssStyleSheet);
var
  Index: Integer;
begin
  Index := FindOwner(Element);
  if Index >= 0 then
  begin
    if Sheet = nil then
    begin
      RemoveAt(Index);
      Exit;
    end;
    if FSheets[Index].OwnedHere then
      RetireSheet(FSheets[Index].Sheet);
    FSheets[Index].Sheet := Sheet;
    FSheets[Index].OwnedHere := False;
    Exit;
  end;
  if Sheet = nil then
    Exit;
  SetLength(FSheets, Length(FSheets) + 1);
  FSheets[High(FSheets)].Owner := Element;
  FSheets[High(FSheets)].Sheet := Sheet;
  FSheets[High(FSheets)].OwnedHere := False;
end;

function TDocumentSheets.LinkSheet(Element: TElement): TCssStyleSheet;
var
  Index: Integer;
begin
  Index := FindOwner(Element);
  if (Index < 0) or FSheets[Index].OwnedHere then
    Exit(nil);
  Result := FSheets[Index].Sheet;
end;

function TDocumentSheets.OwnerOf(Sheet: TCssStyleSheet): TElement;
var
  Index: Integer;
begin
  for Index := 0 to High(FSheets) do
    if FSheets[Index].Sheet = Sheet then
      Exit(FSheets[Index].Owner);
  Result := nil;
end;

procedure TDocumentSheets.ElementRemoved(Element: TElement);
var
  Index: Integer;
begin
  Index := FindOwner(Element);
  if (Index >= 0) and FSheets[Index].OwnedHere then
    RemoveAt(Index);
end;

function TDocumentSheets.NewConstructedSheet(const BaseUrl: string): TCssStyleSheet;
begin
  Result := TCssStyleSheet.Create(coAuthor);
  Result.Href := BaseUrl;
  SetLength(FConstructed, Length(FConstructed) + 1);
  FConstructed[High(FConstructed)] := Result;
end;

function TDocumentSheets.IsConstructed(Sheet: TCssStyleSheet): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(FConstructed) do
    if FConstructed[Index] = Sheet then
      Exit(True);
  Result := False;
end;

procedure TDocumentSheets.SetAdoptedSheets(const Sheets: TCssStyleSheetList);
begin
  FAdopted := Copy(Sheets);
  Notify(scSheetsChanged, nil, nil);
end;

procedure TDocumentSheets.RuleAppended(Sheet: TCssStyleSheet; Rule: TCssRule);
begin
  Notify(scRuleAppended, Sheet, Rule);
end;

procedure TDocumentSheets.ContentsChanged(Sheet: TCssStyleSheet);
begin
  Notify(scContentsChanged, Sheet, nil);
end;

procedure TDocumentSheets.NodeDisconnected(Node: TNode);
begin
  if Node.IsElement and TElement(Node).IsHtmlElement(AtomStyle) then
    ElementRemoved(TElement(Node));
end;

procedure TDocumentSheets.AddListener(Listener: TSheetChangeListener);
begin
  SetLength(FListeners, Length(FListeners) + 1);
  FListeners[High(FListeners)] := Listener;
end;

procedure TDocumentSheets.RemoveListener(Listener: TSheetChangeListener);
var
  Index: Integer;
begin
  for Index := 0 to High(FListeners) do
    if (TMethod(FListeners[Index]).Code = TMethod(Listener).Code) and
      (TMethod(FListeners[Index]).Data = TMethod(Listener).Data) then
    begin
      FListeners[Index] := FListeners[High(FListeners)];
      SetLength(FListeners, Length(FListeners) - 1);
      Exit;
    end;
end;

end.

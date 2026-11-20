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
  @font-face sources (CSS Fonts 4 section 4.3): the src descriptor's
  list is read (url() with an optional format() hint, local() skipped:
  the sink has the system's fonts), and the first url() whose format the
  sink supports is fetched (destination font, CORS mode with
  same-origin credentials, as the standard requires), relative to the
  sheet's URL. A failure tries the next source; the sink gets the bytes
  (FontLoaded) or, when nothing worked, FontFailed. Each face loads
  once; a face of a sheet that goes away is forgotten. Fonts delay the
  load event, as the document's font set does.

  LoadFacesOf walks a sheet, its @media and @supports blocks and its
  imports; LoadFace is for the style side to ask for one face when it
  is first used (the lazy way).
}
unit Web.Loading.Fonts;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records,
  Css.Stylesheets,
  Web.Loading.Contexts,
  Web.Loading.BufferedFetches;

type
  TFontSource = record
    Url: string;
    Format: string;
  end;

  TFontSourceArray = array of TFontSource;

  TFaceLoad = class
  public
    Rule: TCssFontFaceRule;
    Sheet: TCssStyleSheet;
    { The sheet the sink got (Sheet may be one it imports). }
    RootSheet: TCssStyleSheet;
    Base: TUrlRecord;
    Sources: TFontSourceArray;
    NextSource: Integer;
    Fetch: TBufferedFetch;
    Done: Boolean;
    destructor Destroy; override;
  end;

  TFontLoader = class
  private
    FContext: TLoadingContext;
    FFaces: TList;
    function FindFace(Rule: TCssFontFaceRule): TFaceLoad;
    procedure TryNextSource(Face: TFaceLoad);
    procedure SourceComplete(Fetch: TBufferedFetch; Success: Boolean);
    procedure WalkRules(const Rules: TCssRuleArray; Sheet, Root: TCssStyleSheet);
    procedure AddFace(Rule: TCssFontFaceRule; Sheet, Root: TCssStyleSheet);
  public
    constructor Create(Context: TLoadingContext);
    destructor Destroy; override;
    procedure LoadFacesOf(Sheet: TCssStyleSheet);
    procedure LoadFace(Rule: TCssFontFaceRule; Sheet: TCssStyleSheet);
    { The sheet is going: its faces are dropped (loads cancelled). }
    procedure ForgetSheet(Sheet: TCssStyleSheet);
    function LoadingCount: Integer;
  end;

{ The url() sources of an src descriptor, in order, with format() hints
  (lower case, unquoted). }
function ParseFontSources(const Text: string): TFontSourceArray;

implementation

uses
  Url.Parser,
  Web.Fetch.Requests,
  Web.Loading.Priorities;

destructor TFaceLoad.Destroy;
begin
  if Fetch <> nil then
  begin
    Fetch.Cancel;
    Fetch.Free;
  end;
  inherited Destroy;
end;

{ The argument of name(...) starting at Position (just after "("). }
function ReadFunctionArgument(const Text: string; var Position: Integer): string;
var
  Start: Integer;
  Quote: Char;
begin
  while (Position <= Length(Text)) and (Text[Position] in [' ', #9, #10, #13, #12]) do
    Inc(Position);
  if (Position <= Length(Text)) and (Text[Position] in ['"', '''']) then
  begin
    Quote := Text[Position];
    Inc(Position);
    Start := Position;
    while (Position <= Length(Text)) and (Text[Position] <> Quote) do
    begin
      if Text[Position] = '\' then
        Inc(Position);
      Inc(Position);
    end;
    Result := Copy(Text, Start, Position - Start);
    Inc(Position);
  end
  else
  begin
    Start := Position;
    while (Position <= Length(Text)) and (Text[Position] <> ')') do
      Inc(Position);
    Result := Trim(Copy(Text, Start, Position - Start));
  end;
  while (Position <= Length(Text)) and (Text[Position] <> ')') do
    Inc(Position);
  Inc(Position);
end;

function ParseFontSources(const Text: string): TFontSourceArray;
var
  Position, Start: Integer;
  Name: string;
  Current: TFontSource;
  HasUrl: Boolean;

  procedure Commit;
  begin
    if HasUrl then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Current;
    end;
    HasUrl := False;
    Current := Default(TFontSource);
  end;

begin
  Result := nil;
  Current := Default(TFontSource);
  HasUrl := False;
  Position := 1;
  while Position <= Length(Text) do
  begin
    if Text[Position] = ',' then
    begin
      Commit;
      Inc(Position);
      Continue;
    end;
    if Text[Position] in ['a'..'z', 'A'..'Z', '-'] then
    begin
      Start := Position;
      while (Position <= Length(Text)) and (Text[Position] in ['a'..'z', 'A'..'Z', '-', '0'..'9']) do
        Inc(Position);
      Name := LowerCase(Copy(Text, Start, Position - Start));
      if (Position <= Length(Text)) and (Text[Position] = '(') then
      begin
        Inc(Position);
        if Name = 'url' then
        begin
          Current.Url := ReadFunctionArgument(Text, Position);
          HasUrl := True;
        end
        else if Name = 'format' then
          Current.Format := LowerCase(ReadFunctionArgument(Text, Position))
        else
          ReadFunctionArgument(Text, Position);
      end;
      Continue;
    end;
    if Text[Position] in ['"', ''''] then
    begin
      ReadFunctionArgument(Text, Position);
      Continue;
    end;
    Inc(Position);
  end;
  Commit;
end;

constructor TFontLoader.Create(Context: TLoadingContext);
begin
  inherited Create;
  FContext := Context;
  FFaces := TList.Create;
end;

destructor TFontLoader.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FFaces.Count - 1 do
    TFaceLoad(FFaces[Index]).Free;
  FFaces.Free;
  inherited Destroy;
end;

function TFontLoader.FindFace(Rule: TCssFontFaceRule): TFaceLoad;
var
  Index: Integer;
begin
  for Index := 0 to FFaces.Count - 1 do
    if TFaceLoad(FFaces[Index]).Rule = Rule then
      Exit(TFaceLoad(FFaces[Index]));
  Result := nil;
end;

procedure TFontLoader.WalkRules(const Rules: TCssRuleArray; Sheet, Root: TCssStyleSheet);
var
  Index: Integer;
  Rule: TCssRule;
begin
  for Index := 0 to High(Rules) do
  begin
    Rule := Rules[Index];
    if Rule is TCssFontFaceRule then
      AddFace(TCssFontFaceRule(Rule), Sheet, Root)
    else if (Rule is TCssImportRule) and (TCssImportRule(Rule).StyleSheet <> nil) then
      WalkRules(TCssImportRule(Rule).StyleSheet.Rules, TCssImportRule(Rule).StyleSheet, Root)
    else if (Rule is TCssSupportsRule) and TCssSupportsRule(Rule).Matches then
      WalkRules(TCssSupportsRule(Rule).Rules, Sheet, Root)
    else if Rule is TCssMediaRule then
      WalkRules(TCssMediaRule(Rule).Rules, Sheet, Root)
    else if Rule is TCssLayerBlockRule then
      WalkRules(TCssLayerBlockRule(Rule).Rules, Sheet, Root);
  end;
end;

procedure TFontLoader.LoadFacesOf(Sheet: TCssStyleSheet);
begin
  WalkRules(Sheet.Rules, Sheet, Sheet);
end;

procedure TFontLoader.LoadFace(Rule: TCssFontFaceRule; Sheet: TCssStyleSheet);
begin
  AddFace(Rule, Sheet, Sheet);
end;

procedure TFontLoader.AddFace(Rule: TCssFontFaceRule; Sheet, Root: TCssStyleSheet);
var
  Face: TFaceLoad;
begin
  if FindFace(Rule) <> nil then
    Exit;
  Face := TFaceLoad.Create;
  Face.Rule := Rule;
  Face.Sheet := Sheet;
  Face.RootSheet := Root;
  if (Sheet = nil) or (Sheet.Href = '') or not ParseUrl(Sheet.Href, Face.Base) then
    Face.Base := FContext.BaseUrl;
  Face.Sources := ParseFontSources(Rule.DescriptorText('src'));
  FFaces.Add(Face);
  FContext.DelayLoad;
  TryNextSource(Face);
end;

procedure TFontLoader.TryNextSource(Face: TFaceLoad);
var
  Source: TFontSource;
  Target: TUrlRecord;
  Request: TFetchRequest;
begin
  while Face.NextSource <= High(Face.Sources) do
  begin
    Source := Face.Sources[Face.NextSource];
    Inc(Face.NextSource);
    if not FContext.Sink.FontFormatSupported(Source.Format) or not ParseUrl(Source.Url, Face.Base, Target) then
      Continue;
    Request := FContext.NewRequest(Target, DestinationFont, FetchModeCors, FetchCredentialsSameOrigin);
    Request.ReferrerKind := ReferrerUrl;
    Request.ReferrerUrl := Face.Base;
    Request.InitiatorType := 'css';
    Request.Priority := PriorityFor(ResourceFont);
    Face.Fetch := TBufferedFetch.Create(@SourceComplete);
    Face.Fetch.Data := Face;
    Face.Fetch.Start(FContext.Fetcher, Request, FContext);
    Exit;
  end;
  Face.Done := True;
  FContext.Sink.FontFailed(Face.Rule, Face.Rule.Family);
  FContext.UndelayLoad;
end;

procedure TFontLoader.SourceComplete(Fetch: TBufferedFetch; Success: Boolean);
var
  Face: TFaceLoad;
  Bytes: TBytes;
  Body: string;
begin
  Face := TFaceLoad(Fetch.Data);
  Face.Fetch := nil;
  if Success and (Fetch.Body <> '') then
  begin
    Body := Fetch.Body;
    Bytes := nil;
    SetLength(Bytes, Length(Body));
    Move(Body[1], Bytes[0], Length(Body));
    Face.Done := True;
    FContext.Sink.FontLoaded(Face.Rule, Face.Rule.Family, Bytes, SerializeUrl(Fetch.FinalUrl));
    Fetch.Free;
    FContext.UndelayLoad;
    Exit;
  end;
  Fetch.Free;
  TryNextSource(Face);
end;

procedure TFontLoader.ForgetSheet(Sheet: TCssStyleSheet);
var
  Index: Integer;
  Face: TFaceLoad;
begin
  for Index := FFaces.Count - 1 downto 0 do
  begin
    Face := TFaceLoad(FFaces[Index]);
    if (Face.RootSheet = Sheet) or (Face.Sheet = Sheet) then
    begin
      if not Face.Done then
        FContext.UndelayLoad;
      Face.Free;
      FFaces.Delete(Index);
    end;
  end;
end;

function TFontLoader.LoadingCount: Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to FFaces.Count - 1 do
    if not TFaceLoad(FFaces[Index]).Done then
      Inc(Result);
end;

end.

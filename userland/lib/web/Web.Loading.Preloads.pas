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
  Fetches made before the element that needs them exists:

  - The preload cache: speculative fetches (and <link rel=preload>)
    keyed by URL and destination. A loader that is about to fetch the
    same thing claims the entry instead and gets the response, already
    complete or still arriving; what nobody claimed by the load event is
    dropped. What a loader has asked for (claimed or not) is never
    fetched speculatively again: the scanner sees bytes the parser has
    already acted on.
  - The preload scanner (HTML Standard 13.2.1, "speculative HTML
    parsing"): while the parser waits for a script, the bytes that
    arrive are scanned by a light tokenizer for <link rel=stylesheet>,
    <link rel=preload>, <script src>, <img src/srcset> (and <base href>
    for resolving them), skipping comments and raw text, and their
    fetches start at a low priority. Scanning assumes an ASCII
    compatible encoding (what the bytes of markup are in practice).
}
unit Web.Loading.Preloads;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records,
  Web.EventLoop.Tasks,
  Web.Fetch.Requests,
  Web.Loading.Contexts,
  Web.Loading.BufferedFetches;

type
  TPreloadEntry = class
  public
    Key: string;
    Fetch: TBufferedFetch;
    Claimed: Boolean;
    Success: Boolean;
    Done: Boolean;
    Waiter: TBufferedFetchEvent;
    Speculative: Boolean;
  end;

  TPreloadCache = class
  private
    FContext: TLoadingContext;
    FEntries: TList;
    FSpeculativeCount: Integer;
    { The keys loaders asked for (sorted, for the scanner to skip). }
    FAskedFor: TStringList;
    procedure EntryComplete(Fetch: TBufferedFetch; Success: Boolean);
    procedure DeliverLate(Data: TObject);
    function Find(const Key: string): TPreloadEntry;
  public
    constructor Create(Context: TLoadingContext);
    destructor Destroy; override;
    class function KeyOf(constref Url: TUrlRecord; Destination: TFetchDestination): string;
    { Starts a fetch for later (nothing if one is there). }
    procedure Preload(Request: TFetchRequest; Speculative: Boolean);
    { An earlier fetch of the same thing, handed over: OnComplete is
      called with it (now done or later), and the caller owns it after
      that call. False: nothing was preloaded. }
    function Claim(constref Url: TUrlRecord; Destination: TFetchDestination; OnComplete: TBufferedFetchEvent;
      out Fetch: TBufferedFetch): Boolean;
    { Drops the entries nobody claimed. }
    procedure DropUnclaimed;
    property SpeculativeCount: Integer read FSpeculativeCount;
  end;

  TPreloadScanner = class
  private
    FContext: TLoadingContext;
    FCache: TPreloadCache;
    FCarry: string;
    FRawTextEnd: string;
    FInComment: Boolean;
    FBase: TUrlRecord;
    FHasBase: Boolean;
    procedure ScanTag(const Tag: string);
    procedure Speculate(const Href: string; Destination: TFetchDestination; Mode: TFetchMode);
  public
    constructor Create(Context: TLoadingContext; Cache: TPreloadCache);
    { More bytes of the document (in order). }
    procedure Scan(const Bytes: string);
  end;

{ The attributes of a start tag's text (after the name), lower case
  names, values unquoted. }
procedure ParseTagAttributes(const Text: string; Names, Values: TStrings);

implementation

uses
  StrUtils,
  Url.Parser,
  Web.Atoms,
  Web.Loading.Priorities;

constructor TPreloadCache.Create(Context: TLoadingContext);
begin
  inherited Create;
  FContext := Context;
  FEntries := TList.Create;
  FAskedFor := TStringList.Create;
  FAskedFor.Sorted := True;
  FAskedFor.Duplicates := dupIgnore;
end;

destructor TPreloadCache.Destroy;
var
  Index: Integer;
  Entry: TPreloadEntry;
begin
  for Index := 0 to FEntries.Count - 1 do
  begin
    Entry := TPreloadEntry(FEntries[Index]);
    if not Entry.Claimed then
    begin
      Entry.Fetch.Cancel;
      Entry.Fetch.Free;
    end;
    Entry.Free;
  end;
  FEntries.Free;
  FAskedFor.Free;
  inherited Destroy;
end;

class function TPreloadCache.KeyOf(constref Url: TUrlRecord; Destination: TFetchDestination): string;
begin
  Result := DestinationName(Destination) + ' ' + SerializeUrl(Url, True);
end;

function TPreloadCache.Find(const Key: string): TPreloadEntry;
var
  Index: Integer;
begin
  for Index := 0 to FEntries.Count - 1 do
    if TPreloadEntry(FEntries[Index]).Key = Key then
      Exit(TPreloadEntry(FEntries[Index]));
  Result := nil;
end;

procedure TPreloadCache.Preload(Request: TFetchRequest; Speculative: Boolean);
var
  Entry: TPreloadEntry;
  Key: string;
begin
  Key := KeyOf(Request.Url, Request.Destination);
  if (Find(Key) <> nil) or (Speculative and (FAskedFor.IndexOf(Key) >= 0)) then
  begin
    Request.Free;
    Exit;
  end;
  Entry := TPreloadEntry.Create;
  Entry.Key := Key;
  Entry.Speculative := Speculative;
  Entry.Fetch := TBufferedFetch.Create(@EntryComplete);
  Entry.Fetch.Data := Entry;
  FEntries.Add(Entry);
  if Speculative then
    Inc(FSpeculativeCount);
  Entry.Fetch.Start(FContext.Fetcher, Request, FContext);
end;

procedure TPreloadCache.EntryComplete(Fetch: TBufferedFetch; Success: Boolean);
var
  Entry: TPreloadEntry;
begin
  { Only unclaimed entries come here: a claim takes the fetch over. }
  Entry := TPreloadEntry(Fetch.Data);
  Entry.Done := True;
  Entry.Success := Success;
end;

function TPreloadCache.Claim(constref Url: TUrlRecord; Destination: TFetchDestination;
  OnComplete: TBufferedFetchEvent; out Fetch: TBufferedFetch): Boolean;
var
  Entry: TPreloadEntry;
  Late: TLateCompletion;
begin
  Fetch := nil;
  FAskedFor.Add(KeyOf(Url, Destination));
  Entry := Find(KeyOf(Url, Destination));
  if Entry = nil then
    Exit(False);
  Fetch := Entry.Fetch;
  if Entry.Done then
  begin
    FEntries.Remove(Entry);
    Fetch.Data := nil;
    Fetch.OnComplete := OnComplete;
    Late := TLateCompletion.Create;
    Late.Fetch := Fetch;
    Late.Success := Entry.Success;
    Fetch.PendingLate := Late;
    Entry.Free;
    FContext.Loop.QueueTask(TDataTask.Create(@DeliverLate, Late), TaskSourceNetworking, FContext);
  end
  else
  begin
    { Still arriving: it completes straight into the claimer. }
    FEntries.Remove(Entry);
    Fetch.Data := nil;
    Fetch.OnComplete := OnComplete;
    Entry.Free;
  end;
  Result := True;
end;

procedure TPreloadCache.DeliverLate(Data: TObject);
begin
  TLateCompletion(Data).Deliver;
end;

procedure TPreloadCache.DropUnclaimed;
var
  Index: Integer;
  Entry: TPreloadEntry;
begin
  for Index := FEntries.Count - 1 downto 0 do
  begin
    Entry := TPreloadEntry(FEntries[Index]);
    if not Entry.Claimed then
    begin
      Entry.Fetch.Cancel;
      Entry.Fetch.Free;
      Entry.Free;
      FEntries.Delete(Index);
    end;
  end;
end;

{ ---- the scanner ---- }

procedure ParseTagAttributes(const Text: string; Names, Values: TStrings);
var
  Position, Start: Integer;
  Name, Value: string;
  Quote: Char;
begin
  Position := 1;
  while Position <= Length(Text) do
  begin
    while (Position <= Length(Text)) and (Text[Position] in [#9, #10, #12, #13, ' ', '/']) do
      Inc(Position);
    Start := Position;
    while (Position <= Length(Text)) and not (Text[Position] in [#9, #10, #12, #13, ' ', '/', '=', '>']) do
      Inc(Position);
    Name := AsciiLowerCase(Copy(Text, Start, Position - Start));
    while (Position <= Length(Text)) and (Text[Position] in [#9, #10, #12, #13, ' ']) do
      Inc(Position);
    Value := '';
    if (Position <= Length(Text)) and (Text[Position] = '=') then
    begin
      Inc(Position);
      while (Position <= Length(Text)) and (Text[Position] in [#9, #10, #12, #13, ' ']) do
        Inc(Position);
      if (Position <= Length(Text)) and (Text[Position] in ['"', '''']) then
      begin
        Quote := Text[Position];
        Inc(Position);
        Start := Position;
        while (Position <= Length(Text)) and (Text[Position] <> Quote) do
          Inc(Position);
        Value := Copy(Text, Start, Position - Start);
        Inc(Position);
      end
      else
      begin
        Start := Position;
        while (Position <= Length(Text)) and not (Text[Position] in [#9, #10, #12, #13, ' ', '>']) do
          Inc(Position);
        Value := Copy(Text, Start, Position - Start);
      end;
    end;
    if Name = '' then
    begin
      if Position <= Length(Text) then
        Inc(Position);
      Continue;
    end;
    if Names.IndexOf(Name) < 0 then
    begin
      Names.Add(Name);
      Values.Add(Value);
    end;
  end;
end;

constructor TPreloadScanner.Create(Context: TLoadingContext; Cache: TPreloadCache);
begin
  inherited Create;
  FContext := Context;
  FCache := Cache;
end;

procedure TPreloadScanner.Speculate(const Href: string; Destination: TFetchDestination; Mode: TFetchMode);
var
  Url: TUrlRecord;
  Base: TUrlRecord;
  Request: TFetchRequest;
begin
  if Href = '' then
    Exit;
  if FHasBase then
    Base := FBase
  else
    Base := FContext.BaseUrl;
  if not ParseUrl(Href, Base, Url) or ((Url.Scheme <> 'http') and (Url.Scheme <> 'https')) then
    Exit;
  Request := FContext.NewRequest(Url, Destination, Mode, FetchCredentialsSameOrigin);
  Request.Priority := PriorityFor(ResourceSpeculative);
  if Destination = DestinationImage then
    Request.SniffContent := True;
  FCache.Preload(Request, True);
end;

function FirstSrcsetUrl(const Srcset: string): string;
var
  Position, Start: Integer;
begin
  Position := 1;
  while (Position <= Length(Srcset)) and (Srcset[Position] in [#9, #10, #12, #13, ' ', ',']) do
    Inc(Position);
  Start := Position;
  while (Position <= Length(Srcset)) and not (Srcset[Position] in [#9, #10, #12, #13, ' ']) do
    Inc(Position);
  Result := Copy(Srcset, Start, Position - Start);
  if (Result <> '') and (Result[Length(Result)] = ',') then
    SetLength(Result, Length(Result) - 1);
end;

function HasToken(const List, Token: string): Boolean;
var
  Parts: TStringArray;
  Index: Integer;
begin
  Parts := AsciiLowerCase(List).Split([' ', #9, #10, #12, #13], TStringSplitOptions.ExcludeEmpty);
  for Index := 0 to High(Parts) do
    if Parts[Index] = Token then
      Exit(True);
  Result := False;
end;

procedure TPreloadScanner.ScanTag(const Tag: string);
var
  NameEnd: Integer;
  Name, Rest, Rel, AsValue: string;
  Names, Values: TStringList;
  Url: TUrlRecord;

  function Attribute(const AttributeName: string): string;
  var
    Index: Integer;
  begin
    Index := Names.IndexOf(AttributeName);
    if Index < 0 then
      Result := ''
    else
      Result := Values[Index];
  end;

begin
  NameEnd := 1;
  while (NameEnd <= Length(Tag)) and not (Tag[NameEnd] in [#9, #10, #12, #13, ' ', '/', '>']) do
    Inc(NameEnd);
  Name := AsciiLowerCase(Copy(Tag, 1, NameEnd - 1));
  if (Name = 'script') or (Name = 'style') or (Name = 'textarea') or (Name = 'title') or (Name = 'xmp') or
     (Name = 'noscript') and FContext.Document.ScriptingEnabled then
    FRawTextEnd := '</' + Name;
  if (Name <> 'link') and (Name <> 'script') and (Name <> 'img') and (Name <> 'base') then
    Exit;
  Rest := Copy(Tag, NameEnd, MaxInt);
  Names := TStringList.Create;
  Values := TStringList.Create;
  try
    ParseTagAttributes(Rest, Names, Values);
    if Name = 'base' then
    begin
      if not FHasBase and (Names.IndexOf('href') >= 0) and ParseUrl(Attribute('href'), FContext.DocumentUrl, Url) then
      begin
        FBase := Url;
        FHasBase := True;
      end;
    end
    else if Name = 'link' then
    begin
      Rel := Attribute('rel');
      if HasToken(Rel, 'stylesheet') and not HasToken(Rel, 'alternate') and (Names.IndexOf('disabled') < 0) then
        Speculate(Attribute('href'), DestinationStyle, FetchModeNoCors)
      else if HasToken(Rel, 'preload') then
      begin
        AsValue := AsciiLowerCase(Attribute('as'));
        if AsValue = 'style' then
          Speculate(Attribute('href'), DestinationStyle, FetchModeNoCors)
        else if AsValue = 'script' then
          Speculate(Attribute('href'), DestinationScript, FetchModeNoCors)
        else if AsValue = 'image' then
          Speculate(Attribute('href'), DestinationImage, FetchModeNoCors)
        else if AsValue = 'font' then
          Speculate(Attribute('href'), DestinationFont, FetchModeCors);
      end;
    end
    else if Name = 'script' then
    begin
      if (Names.IndexOf('src') >= 0) and FContext.Document.ScriptingEnabled and
         (AsciiLowerCase(Attribute('type')) <> 'module') and (Names.IndexOf('crossorigin') < 0) then
        Speculate(Attribute('src'), DestinationScript, FetchModeNoCors);
    end
    else if (Name = 'img') and FContext.Settings.LoadImages and (Names.IndexOf('crossorigin') < 0) then
    begin
      if Names.IndexOf('srcset') >= 0 then
        Speculate(FirstSrcsetUrl(Attribute('srcset')), DestinationImage, FetchModeNoCors)
      else
        Speculate(Attribute('src'), DestinationImage, FetchModeNoCors);
    end;
  finally
    Names.Free;
    Values.Free;
  end;
end;

{ Where Needle is in Text from Start on, counted from Start (1 there),
  or 0. }
function RelativePos(const Needle, Text: string; Start: Integer): Integer;
begin
  Result := PosEx(Needle, Text, Start);
  if Result > 0 then
    Result := Result - Start + 1;
end;

procedure TPreloadScanner.Scan(const Bytes: string);
var
  Text, Lower: string;
  Position, Found, Closing: Integer;
begin
  Text := FCarry + Bytes;
  Lower := AsciiLowerCase(Text);
  FCarry := '';
  Position := 1;
  while Position <= Length(Text) do
  begin
    if FInComment then
    begin
      Found := RelativePos('-->', Text, Position);
      if Found = 0 then
      begin
        FCarry := Copy(Text, Length(Text) - 1, 2);
        Exit;
      end;
      Inc(Position, Found + 2);
      FInComment := False;
      Continue;
    end;
    if FRawTextEnd <> '' then
    begin
      Found := RelativePos(FRawTextEnd, Lower, Position);
      if Found = 0 then
      begin
        FCarry := Copy(Text, Length(Text) - Length(FRawTextEnd) + 1, Length(FRawTextEnd));
        Exit;
      end;
      Inc(Position, Found - 1 + Length(FRawTextEnd));
      FRawTextEnd := '';
      Continue;
    end;
    Found := RelativePos('<', Text, Position);
    if Found = 0 then
      Exit;
    Position := Position + Found - 1;
    if Copy(Text, Position, 4) = '<!--' then
    begin
      FInComment := True;
      Inc(Position, 4);
      Continue;
    end;
    Closing := RelativePos('>', Text, Position);
    if Closing = 0 then
    begin
      FCarry := Copy(Text, Position, MaxInt);
      if Length(FCarry) > 8192 then
        FCarry := '';
      Exit;
    end;
    if (Position < Length(Text)) and (Text[Position + 1] in ['A'..'Z', 'a'..'z']) then
      ScanTag(Copy(Text, Position + 1, Closing - 1));
    Inc(Position, Closing);
  end;
end;

end.

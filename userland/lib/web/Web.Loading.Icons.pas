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
  The document's icon for the browser (HTML Standard 4.6.7.8, link type
  "icon"): once the document has been parsed (and again when icon links
  change afterwards), the best <link rel=icon> is chosen - one whose
  sizes has the size closest above 16 CSS pixels at the device pixel
  ratio, else "any", else the last one in tree order; types libimage
  cannot decode are skipped - or, without one, /favicon.ico of an http
  or https document. It is fetched at the lowest urgency, decoded (an
  ICO's best size) and handed to OnIconChanged; it never delays the
  load event.
}
unit Web.Loading.Icons;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records,
  Image.Model,
  Web.Dom,
  Web.Loading.Contexts,
  Web.Loading.BufferedFetches;

type
  { The icon (owned by the receiver), or nil when there is none. }
  TIconChangedEvent = procedure(const Url: string; Image: TImage) of object;

  TIconLoader = class
  private
    FContext: TLoadingContext;
    FLinks: TList;
    FFetch: TBufferedFetch;
    FCurrentKey: string;
    FActive: Boolean;
    FOnIconChanged: TIconChangedEvent;
    function ChooseIcon(out Url: TUrlRecord): Boolean;
    procedure IconComplete(Fetch: TBufferedFetch; Success: Boolean);
  public
    constructor Create(Context: TLoadingContext);
    destructor Destroy; override;
    procedure LinkChanged(Element: TElement);
    procedure LinkRemoved(Element: TElement);
    { The document is parsed: choose and load (and follow changes). }
    procedure Activate;
    procedure Refresh;
    property OnIconChanged: TIconChangedEvent read FOnIconChanged write FOnIconChanged;
  end;

implementation

uses
  Url.Parser,
  Image.Files,
  Image.Errors,
  Web.Atoms,
  Web.Fetch.Requests,
  Web.Fetch.MimeTypes,
  Web.Loading.Priorities,
  Web.Loading.Srcset,
  Web.Loading.StyleSheets;

constructor TIconLoader.Create(Context: TLoadingContext);
begin
  inherited Create;
  FContext := Context;
  FLinks := TList.Create;
end;

destructor TIconLoader.Destroy;
var
  Index: Integer;
begin
  if FFetch <> nil then
  begin
    FFetch.Cancel;
    FFetch.Free;
  end;
  for Index := 0 to FLinks.Count - 1 do
    TElement(FLinks[Index]).Release;
  FLinks.Free;
  inherited Destroy;
end;

procedure TIconLoader.LinkChanged(Element: TElement);
var
  Listed: Boolean;
begin
  Listed := FLinks.IndexOf(Element) >= 0;
  if RelHasToken(Element, 'icon') and Element.IsConnected then
  begin
    if not Listed then
    begin
      Element.Retain;
      FLinks.Add(Element);
    end;
  end
  else if Listed then
  begin
    FLinks.Remove(Element);
    Element.Release;
  end;
  if FActive then
    Refresh;
end;

procedure TIconLoader.LinkRemoved(Element: TElement);
begin
  if FLinks.IndexOf(Element) < 0 then
    Exit;
  FLinks.Remove(Element);
  Element.Release;
  if FActive then
    Refresh;
end;

{ The size in a sizes attribute closest above Wanted (or the largest),
  0 for none, MaxInt for "any". }
function BestListedSize(const Sizes: string; Wanted: Integer): Integer;
var
  Parts: TStringArray;
  Index, Cross, Side: Integer;
begin
  Result := 0;
  Parts := AsciiLowerCase(Sizes).Split([' ', #9, #10, #12, #13], TStringSplitOptions.ExcludeEmpty);
  for Index := 0 to High(Parts) do
  begin
    if Parts[Index] = 'any' then
      Exit(MaxInt);
    Cross := Pos('x', Parts[Index]);
    if Cross = 0 then
      Continue;
    Side := StrToIntDef(Copy(Parts[Index], 1, Cross - 1), 0);
    if Side <= 0 then
      Continue;
    if (Result = 0) or (Side >= Wanted) and ((Result < Wanted) or (Side < Result)) or
       (Result < Wanted) and (Side > Result) then
      Result := Side;
  end;
end;

function TIconLoader.ChooseIcon(out Url: TUrlRecord): Boolean;
var
  Index, Wanted, Size, BestSize: Integer;
  Element, Best: TElement;
  Ratio: Double;
  TypeText: string;
begin
  Ratio := FContext.Sink.MediaEnvironment.Resolution;
  if Ratio <= 0 then
    Ratio := 1;
  Wanted := Round(16 * Ratio);
  Best := nil;
  BestSize := -1;
  for Index := 0 to FLinks.Count - 1 do
  begin
    Element := TElement(FLinks[Index]);
    if Element.AttributeValueOf(AtomHref) = '' then
      Continue;
    TypeText := Element.AttributeValueOf(AtomType);
    if (TypeText <> '') and not IsSupportedImageType(MimeEssence(ParseMimeType(TypeText))) then
      Continue;
    Size := BestListedSize(Element.AttributeValueOf(AtomSizes), Wanted);
    if Size = MaxInt then
      Size := Wanted;
    { Equal sizes: the later link wins (tree order, last). }
    if (Best = nil) or (Size >= Wanted) and ((BestSize < Wanted) or (Size <= BestSize)) or
       (BestSize < Wanted) and (Size >= BestSize) then
    begin
      Best := Element;
      BestSize := Size;
    end;
  end;
  if Best <> nil then
    Exit(FContext.ResolveUrl(Best.AttributeValueOf(AtomHref), Url));
  Url := FContext.DocumentUrl;
  Result := (Url.Scheme = 'http') or (Url.Scheme = 'https');
  if Result then
    Result := ParseUrl('/favicon.ico', FContext.DocumentUrl, Url);
end;

procedure TIconLoader.Activate;
begin
  FActive := True;
  Refresh;
end;

procedure TIconLoader.Refresh;
var
  Url: TUrlRecord;
  Key: string;
  Request: TFetchRequest;
begin
  if not FContext.Settings.LoadIcons then
    Exit;
  if not ChooseIcon(Url) then
  begin
    if FCurrentKey <> '' then
    begin
      FCurrentKey := '';
      if Assigned(FOnIconChanged) then
        FOnIconChanged('', nil);
    end;
    Exit;
  end;
  Key := SerializeUrl(Url);
  if Key = FCurrentKey then
    Exit;
  FCurrentKey := Key;
  if FFetch <> nil then
  begin
    FFetch.Cancel;
    FreeAndNil(FFetch);
  end;
  Request := FContext.NewRequest(Url, DestinationImage, FetchModeNoCors, FetchCredentialsInclude);
  Request.InitiatorType := 'link';
  Request.SniffContent := True;
  Request.Priority := PriorityFor(ResourceIcon);
  FFetch := TBufferedFetch.Create(@IconComplete);
  FFetch.Start(FContext.Fetcher, Request, FContext);
end;

procedure TIconLoader.IconComplete(Fetch: TBufferedFetch; Success: Boolean);
var
  Image: TImage;
  Reason: TImageErrorReason;
  Body: string;
  Bytes: TBytes;
begin
  FFetch := nil;
  Body := Fetch.Body;
  Fetch.Free;
  Image := nil;
  if Success and (Body <> '') then
  begin
    Bytes := nil;
    SetLength(Bytes, Length(Body));
    Move(Body[1], Bytes[0], Length(Body));
    if not TryLoadImage(Bytes, Image, Reason, [ImageLoadConvertToSrgb]) then
      Image := nil;
  end;
  if Assigned(FOnIconChanged) then
  begin
    if Image <> nil then
      FOnIconChanged(FCurrentKey, Image)
    else
      FOnIconChanged('', nil);
  end
  else
    Image.Free;
end;

end.

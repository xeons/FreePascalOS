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
  Request priorities (RFC 9218 urgency 0 to 7, lower first, and the
  incremental flag) for what a document loads, in the spirit of the
  browsers' tables:

    0  the document itself
    1  render-blocking style sheets, parser-blocking scripts, preloaded
       fonts
    2  fonts, other scripts in the head
    3  images in the viewport (the default), async scripts
    4  deferred scripts
    5  other images, style sheets whose media does not match
    6  speculative fetches of the preload scanner
    7  favicons, prefetches

  Documents and images are incremental (they are used as they arrive).
  fetchpriority=high moves one level up, low one down.
}
unit Web.Loading.Priorities;

{$mode objfpc}
{$H+}

interface

uses
  Http.Priorities,
  Web.Fetch.Requests;

type
  TResourceKind = (
    ResourceDocument,
    ResourceBlockingStyle,
    ResourceStyle,
    ResourceNonMatchingStyle,
    ResourceBlockingScript,
    ResourceAsyncScript,
    ResourceDeferredScript,
    ResourceFont,
    ResourceVisibleImage,
    ResourceImage,
    ResourceSpeculative,
    ResourceIcon);

function PriorityFor(Kind: TResourceKind; Hint: TFetchPriorityHint = FetchPriorityAuto): THttpPriority;
{ The fetchpriority attribute's value. }
function FetchPriorityFromAttribute(const Value: string): TFetchPriorityHint;

implementation

uses
  SysUtils;

function PriorityFor(Kind: TResourceKind; Hint: TFetchPriorityHint): THttpPriority;
var
  Urgency: Integer;
  Incremental: Boolean;
begin
  Incremental := False;
  case Kind of
    ResourceDocument:
      begin
        Urgency := 0;
        Incremental := True;
      end;
    ResourceBlockingStyle, ResourceBlockingScript: Urgency := 1;
    ResourceStyle, ResourceFont: Urgency := 2;
    ResourceAsyncScript: Urgency := 3;
    ResourceVisibleImage:
      begin
        Urgency := 3;
        Incremental := True;
      end;
    ResourceDeferredScript: Urgency := 4;
    ResourceImage:
      begin
        Urgency := 5;
        Incremental := True;
      end;
    ResourceNonMatchingStyle: Urgency := 5;
    ResourceSpeculative: Urgency := 6;
  else
    Urgency := 7;
  end;
  if (Hint = FetchPriorityHigh) and (Urgency > 0) then
    Dec(Urgency)
  else if (Hint = FetchPriorityLow) and (Urgency < LowestUrgency) then
    Inc(Urgency);
  Result := MakePriority(Urgency, Incremental);
end;

function FetchPriorityFromAttribute(const Value: string): TFetchPriorityHint;
begin
  case LowerCase(Value) of
    'high': Result := FetchPriorityHigh;
    'low': Result := FetchPriorityLow;
  else
    Result := FetchPriorityAuto;
  end;
end;

end.

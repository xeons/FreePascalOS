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
  Converting a page's links for viewing it from the disk (-k): each
  link the caller has a replacement for is rewritten in place, from the
  last to the first so the earlier positions stay right. A replacement
  is a relative link to a file that was fetched (with "%", "?", "#"
  and blanks escaped, so a query kept in a file name is not read as a
  query) or the absolute URL of one that was not. Replacements are put
  into the attribute with "&" and quotes written as references.

  Plain Pascal (the RTL only), checked on the host by tools/WgetTest.
}
unit Wget.LinkConversion;

{$mode objfpc}
{$H+}

interface

uses
  Wget.Links;

{ Html with Links[I] replaced by Replacements[I] wherever that is not
  ''. The two arrays have the same length. }
function ReplaceLinks(const Html: string; const Links: TFoundLinkArray; const Replacements: array of string): string;
{ A relative file path as a link ("list.cgi?p=2" -> "list.cgi%3Fp=2"). }
function EscapeLinkPath(const Path: string): string;
{ The text as it may stand in a quoted attribute. }
function EscapeAttributeText(const Text: string): string;

implementation

uses
  SysUtils;

function EscapeLinkPath(const Path: string): string;
var
  Character: Char;
begin
  Result := '';
  for Character in Path do
    case Character of
      '%', '?', '#', ' ', '"', '<', '>':
        Result := Result + '%' + IntToHex(Ord(Character), 2);
    else
      Result := Result + Character;
    end;
end;

function EscapeAttributeText(const Text: string): string;
var
  Character: Char;
begin
  Result := '';
  for Character in Text do
    case Character of
      '&': Result := Result + '&amp;';
      '"': Result := Result + '&quot;';
      '''': Result := Result + '&#39;';
    else
      Result := Result + Character;
    end;
end;

function ReplaceLinks(const Html: string; const Links: TFoundLinkArray; const Replacements: array of string): string;
var
  Order: array of Integer;
  Index, Inner, Swap: Integer;
  Link: TFoundLink;
begin
  Result := Html;
  { The links by position, last first. }
  SetLength(Order, Length(Links));
  for Index := 0 to High(Links) do
    Order[Index] := Index;
  for Index := 1 to High(Order) do
  begin
    Inner := Index;
    while (Inner > 0) and (Links[Order[Inner]].ValueStart > Links[Order[Inner - 1]].ValueStart) do
    begin
      Swap := Order[Inner];
      Order[Inner] := Order[Inner - 1];
      Order[Inner - 1] := Swap;
      Dec(Inner);
    end;
  end;
  for Index := 0 to High(Order) do
  begin
    if (Order[Index] > High(Replacements)) or (Replacements[Order[Index]] = '') then
      Continue;
    Link := Links[Order[Index]];
    Result := Copy(Result, 1, Link.ValueStart - 1) + EscapeAttributeText(Replacements[Order[Index]]) +
      Copy(Result, Link.ValueStart + Link.ValueLength, MaxInt);
  end;
end;

end.

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
  The document mode a DOCTYPE token gives (the "initial" insertion mode):
  quirks, limited quirks or no quirks, from the standard's lists of
  public and system identifiers, compared without regard to ASCII case.
}
unit Web.Html.Quirks;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom,
  Web.Html.Tokens;

function DocumentModeForDoctype(const Token: TToken): TDocumentMode;
{ Whether the DOCTYPE is a parse error (not <!DOCTYPE html> or the
  about:legacy-compat one). }
function IsDoctypeParseError(const Token: TToken): Boolean;

implementation

uses
  Web.Atoms;

const
  QuirksPublicPrefixes: array[0..54] of string = (
    '+//silmaril//dtd html pro v0r11 19970101//',
    '-//as//dtd html 3.0 aswedit + extensions//',
    '-//advasoft ltd//dtd html 3.0 aswedit + extensions//',
    '-//ietf//dtd html 2.0 level 1//',
    '-//ietf//dtd html 2.0 level 2//',
    '-//ietf//dtd html 2.0 strict level 1//',
    '-//ietf//dtd html 2.0 strict level 2//',
    '-//ietf//dtd html 2.0 strict//',
    '-//ietf//dtd html 2.0//',
    '-//ietf//dtd html 2.1e//',
    '-//ietf//dtd html 3.0//',
    '-//ietf//dtd html 3.2 final//',
    '-//ietf//dtd html 3.2//',
    '-//ietf//dtd html 3//',
    '-//ietf//dtd html level 0//',
    '-//ietf//dtd html level 1//',
    '-//ietf//dtd html level 2//',
    '-//ietf//dtd html level 3//',
    '-//ietf//dtd html strict level 0//',
    '-//ietf//dtd html strict level 1//',
    '-//ietf//dtd html strict level 2//',
    '-//ietf//dtd html strict level 3//',
    '-//ietf//dtd html strict//',
    '-//ietf//dtd html//',
    '-//metrius//dtd metrius presentational//',
    '-//microsoft//dtd internet explorer 2.0 html strict//',
    '-//microsoft//dtd internet explorer 2.0 html//',
    '-//microsoft//dtd internet explorer 2.0 tables//',
    '-//microsoft//dtd internet explorer 3.0 html strict//',
    '-//microsoft//dtd internet explorer 3.0 html//',
    '-//microsoft//dtd internet explorer 3.0 tables//',
    '-//netscape comm. corp.//dtd html//',
    '-//netscape comm. corp.//dtd strict html//',
    '-//o''reilly and associates//dtd html 2.0//',
    '-//o''reilly and associates//dtd html extended 1.0//',
    '-//o''reilly and associates//dtd html extended relaxed 1.0//',
    '-//sq//dtd html 2.0 hotmetal + extensions//',
    '-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//',
    '-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//',
    '-//spyglass//dtd html 2.0 extended//',
    '-//sun microsystems corp.//dtd hotjava html//',
    '-//sun microsystems corp.//dtd hotjava strict html//',
    '-//w3c//dtd html 3 1995-03-24//',
    '-//w3c//dtd html 3.2 draft//',
    '-//w3c//dtd html 3.2 final//',
    '-//w3c//dtd html 3.2//',
    '-//w3c//dtd html 3.2s draft//',
    '-//w3c//dtd html 4.0 frameset//',
    '-//w3c//dtd html 4.0 transitional//',
    '-//w3c//dtd html experimental 19960712//',
    '-//w3c//dtd html experimental 970421//',
    '-//w3c//dtd w3 html//',
    '-//w3o//dtd w3 html 3.0//',
    '-//webtechs//dtd mozilla html 2.0//',
    '-//webtechs//dtd mozilla html//');

function StartsWith(const Text, Prefix: string): Boolean;
begin
  Result := Copy(Text, 1, Length(Prefix)) = Prefix;
end;

function DocumentModeForDoctype(const Token: TToken): TDocumentMode;
var
  PublicId, SystemId: string;
  Index: Integer;
begin
  PublicId := AsciiLowerCase(Token.PublicId);
  SystemId := AsciiLowerCase(Token.SystemId);
  if Token.ForceQuirks or (Token.DoctypeName <> 'html') then
    Exit(DocumentModeQuirks);
  if Token.HasPublicId then
  begin
    if (PublicId = '-//w3o//dtd w3 html strict 3.0//en//') or (PublicId = '-/w3c/dtd html 4.0 transitional/en') or
      (PublicId = 'html') then
      Exit(DocumentModeQuirks);
    for Index := 0 to High(QuirksPublicPrefixes) do
      if StartsWith(PublicId, QuirksPublicPrefixes[Index]) then
        Exit(DocumentModeQuirks);
    if not Token.HasSystemId and (StartsWith(PublicId, '-//w3c//dtd html 4.01 frameset//') or
      StartsWith(PublicId, '-//w3c//dtd html 4.01 transitional//')) then
      Exit(DocumentModeQuirks);
  end;
  if Token.HasSystemId and (SystemId = 'http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd') then
    Exit(DocumentModeQuirks);
  if Token.HasPublicId then
  begin
    if StartsWith(PublicId, '-//w3c//dtd xhtml 1.0 frameset//') or
      StartsWith(PublicId, '-//w3c//dtd xhtml 1.0 transitional//') then
      Exit(DocumentModeLimitedQuirks);
    if Token.HasSystemId and (StartsWith(PublicId, '-//w3c//dtd html 4.01 frameset//') or
      StartsWith(PublicId, '-//w3c//dtd html 4.01 transitional//')) then
      Exit(DocumentModeLimitedQuirks);
  end;
  Result := DocumentModeNoQuirks;
end;

function IsDoctypeParseError(const Token: TToken): Boolean;
begin
  Result := (Token.DoctypeName <> 'html') or Token.HasPublicId or
    (Token.HasSystemId and (Token.SystemId <> 'about:legacy-compat'));
end;

end.

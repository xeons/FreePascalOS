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
  The links of an HTML page, for recursion (-r), page requisites (-p)
  and converting links (-k).

  Tags are found by a small scanner (not a full HTML parser): comments,
  and the text of <script> and <style> elements, are skipped; attribute
  values may be quoted with " or ' or bare. A link is

    followed    a href, area href, link href (but stylesheets and icons),
                frame src, iframe src, and the URL of a
                <meta http-equiv="refresh" content="5; url=...">
    a requisite img src, script src, link href with rel stylesheet or
                icon, input src, embed src, audio/video/source/track src,
                object data, body/table/td background

  <base href> gives the base the others are resolved against. Values
  have their character references decoded (&amp; &lt; &gt; &quot;
  &apos; &#N; &#xH;) and surrounding blanks removed; "#fragment" only,
  "javascript:", "mailto:" and "data:" links are left out. Each link
  keeps where its value is in the text, so -k can replace it.

  Plain Pascal (the RTL only), checked on the host by tools/WgetTest.
}
unit Wget.Links;

{$mode objfpc}
{$H+}

interface

type
  TLinkKind = (LinkFollowed, LinkRequisite, LinkBase);

  TFoundLink = record
    Kind: TLinkKind;
    { Decoded, as it is to be resolved. }
    Reference: string;
    { Where the raw value is: its first character and its length. }
    ValueStart: Integer;
    ValueLength: Integer;
  end;

  TFoundLinkArray = array of TFoundLink;

function ExtractLinks(const Html: string): TFoundLinkArray;
{ The base reference of the page ('' when it has no <base href>). }
function FindBaseReference(const Links: TFoundLinkArray): string;
{ Character references decoded. }
function DecodeCharacterReferences(const Text: string): string;

implementation

uses
  SysUtils,
  StrUtils;

type
  TAttribute = record
    Name: string;
    Value: string;
    ValueStart, ValueLength: Integer;
  end;

  TAttributeArray = array of TAttribute;

const
  NameCharacters = ['a'..'z', 'A'..'Z', '0'..'9', '-', '_', ':', '.'];
  Blanks = [' ', #9, #10, #13, #12];

function HexDigitValue(Character: Char): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

{ A code point as UTF-8. }
function Utf8Of(CodePoint: LongWord): string;
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

{ "&...;" at Position: its text and length, or False. }
function DecodeReferenceAt(const Text: string; Position: Integer; out Decoded: string; out Used: Integer): Boolean;
var
  Ending: Integer;
  Name: string;
  CodePoint: LongWord;
  Index: Integer;
  Digit: Integer;
begin
  Result := False;
  Decoded := '';
  Used := 0;
  Ending := PosEx(';', Text, Position);
  if (Ending = 0) or (Ending - Position > 10) then
    Exit;
  Name := Copy(Text, Position + 1, Ending - Position - 1);
  if Name = '' then
    Exit;
  if Name[1] = '#' then
  begin
    CodePoint := 0;
    if (Length(Name) > 2) and (Name[2] in ['x', 'X']) then
    begin
      for Index := 3 to Length(Name) do
      begin
        Digit := HexDigitValue(Name[Index]);
        if Digit < 0 then
          Exit;
        CodePoint := CodePoint * 16 + LongWord(Digit);
      end;
    end
    else
    begin
      if Length(Name) < 2 then
        Exit;
      for Index := 2 to Length(Name) do
      begin
        if not (Name[Index] in ['0'..'9']) then
          Exit;
        CodePoint := CodePoint * 10 + LongWord(Ord(Name[Index]) - Ord('0'));
      end;
    end;
    if (CodePoint = 0) or (CodePoint > $10FFFF) then
      Exit;
    Decoded := Utf8Of(CodePoint);
  end
  else if Name = 'amp' then
    Decoded := '&'
  else if Name = 'lt' then
    Decoded := '<'
  else if Name = 'gt' then
    Decoded := '>'
  else if Name = 'quot' then
    Decoded := '"'
  else if Name = 'apos' then
    Decoded := ''''
  else
    Exit;
  Used := Ending - Position + 1;
  Result := True;
end;

function DecodeCharacterReferences(const Text: string): string;
var
  Position: Integer;
  Decoded: string;
  Used: Integer;
begin
  Result := '';
  Position := 1;
  while Position <= Length(Text) do
  begin
    if (Text[Position] = '&') and DecodeReferenceAt(Text, Position, Decoded, Used) then
    begin
      Result := Result + Decoded;
      Inc(Position, Used);
      Continue;
    end;
    Result := Result + Text[Position];
    Inc(Position);
  end;
end;

{ The attributes of the tag whose name ends just before Position, up to
  its ">"; Position ends after the ">". }
function ReadAttributes(const Html: string; var Position: Integer): TAttributeArray;
var
  Attribute: TAttribute;
  Start: Integer;
  Quote: Char;
begin
  Result := nil;
  while Position <= Length(Html) do
  begin
    while (Position <= Length(Html)) and ((Html[Position] in Blanks) or (Html[Position] = '/')) do
      Inc(Position);
    if Position > Length(Html) then
      Exit;
    if Html[Position] = '>' then
    begin
      Inc(Position);
      Exit;
    end;
    Attribute := Default(TAttribute);
    Start := Position;
    while (Position <= Length(Html)) and not (Html[Position] in Blanks + ['=', '>', '/']) do
      Inc(Position);
    if Position = Start then
    begin
      Inc(Position);
      Continue;
    end;
    Attribute.Name := LowerCase(Copy(Html, Start, Position - Start));
    while (Position <= Length(Html)) and (Html[Position] in Blanks) do
      Inc(Position);
    if (Position <= Length(Html)) and (Html[Position] = '=') then
    begin
      Inc(Position);
      while (Position <= Length(Html)) and (Html[Position] in Blanks) do
        Inc(Position);
      if (Position <= Length(Html)) and (Html[Position] in ['"', '''']) then
      begin
        Quote := Html[Position];
        Inc(Position);
        Start := Position;
        while (Position <= Length(Html)) and (Html[Position] <> Quote) do
          Inc(Position);
        Attribute.ValueStart := Start;
        Attribute.ValueLength := Position - Start;
        if Position <= Length(Html) then
          Inc(Position);
      end
      else
      begin
        Start := Position;
        while (Position <= Length(Html)) and not (Html[Position] in Blanks + ['>']) do
          Inc(Position);
        Attribute.ValueStart := Start;
        Attribute.ValueLength := Position - Start;
      end;
      Attribute.Value := Copy(Html, Attribute.ValueStart, Attribute.ValueLength);
    end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Attribute;
  end;
end;

function FindAttribute(const Attributes: TAttributeArray; const Name: string; out Attribute: TAttribute): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Attributes) do
    if Attributes[Index].Name = Name then
    begin
      Attribute := Attributes[Index];
      Exit(True);
    end;
  Attribute := Default(TAttribute);
  Result := False;
end;

function IsLinkWorthKeeping(const Reference: string): Boolean;
begin
  Result := (Reference <> '') and (Reference[1] <> '#') and not StartsText('javascript:', Reference) and
    not StartsText('mailto:', Reference) and not StartsText('data:', Reference);
end;

{ The value's blanks at both ends are not part of the link. }
procedure AddLink(var Links: TFoundLinkArray; Kind: TLinkKind; constref Attribute: TAttribute; Start, Count: Integer);
var
  Link: TFoundLink;
  Raw: string;
begin
  Raw := Copy(Attribute.Value, Start, Count);
  while (Raw <> '') and (Raw[1] in Blanks) do
  begin
    Delete(Raw, 1, 1);
    Inc(Start);
  end;
  while (Raw <> '') and (Raw[Length(Raw)] in Blanks) do
    SetLength(Raw, Length(Raw) - 1);
  Link.Kind := Kind;
  Link.Reference := DecodeCharacterReferences(Raw);
  Link.ValueStart := Attribute.ValueStart + Start - 1;
  Link.ValueLength := Length(Raw);
  if (Kind = LinkBase) or IsLinkWorthKeeping(Link.Reference) then
  begin
    SetLength(Links, Length(Links) + 1);
    Links[High(Links)] := Link;
  end;
end;

procedure AddAttributeLink(var Links: TFoundLinkArray; const Attributes: TAttributeArray; const Name: string;
  Kind: TLinkKind);
var
  Attribute: TAttribute;
begin
  if FindAttribute(Attributes, Name, Attribute) and (Attribute.ValueLength > 0) then
    AddLink(Links, Kind, Attribute, 1, Length(Attribute.Value));
end;

{ rel="stylesheet", "icon", "shortcut icon", "apple-touch-icon"... }
function IsRequisiteRelation(const Relation: string): Boolean;
var
  Word: string;
begin
  for Word in LowerCase(Relation).Split([' ', #9]) do
    if (Word = 'stylesheet') or (Word = 'icon') or (Word = 'apple-touch-icon') or (Word = 'preload') then
      Exit(True);
  Result := False;
end;

{ <meta http-equiv="refresh" content="5; url=next.html"> }
procedure AddRefreshLink(var Links: TFoundLinkArray; const Attributes: TAttributeArray);
var
  Equivalent, Content: TAttribute;
  UrlStart: Integer;
  Lower: string;
begin
  if not FindAttribute(Attributes, 'http-equiv', Equivalent) or
     not SameText(Trim(Equivalent.Value), 'refresh') then
    Exit;
  if not FindAttribute(Attributes, 'content', Content) then
    Exit;
  Lower := LowerCase(Content.Value);
  UrlStart := Pos('url=', Lower);
  if UrlStart = 0 then
    Exit;
  UrlStart := UrlStart + 4;
  AddLink(Links, LinkFollowed, Content, UrlStart, Length(Content.Value) - UrlStart + 1);
end;

procedure AddTagLinks(var Links: TFoundLinkArray; const Tag: string; const Attributes: TAttributeArray);
var
  Relation: TAttribute;
begin
  if (Tag = 'a') or (Tag = 'area') then
    AddAttributeLink(Links, Attributes, 'href', LinkFollowed)
  else if Tag = 'base' then
    AddAttributeLink(Links, Attributes, 'href', LinkBase)
  else if Tag = 'link' then
  begin
    if FindAttribute(Attributes, 'rel', Relation) and IsRequisiteRelation(Relation.Value) then
      AddAttributeLink(Links, Attributes, 'href', LinkRequisite)
    else
      AddAttributeLink(Links, Attributes, 'href', LinkFollowed);
  end
  else if (Tag = 'frame') or (Tag = 'iframe') then
    AddAttributeLink(Links, Attributes, 'src', LinkFollowed)
  else if (Tag = 'img') or (Tag = 'script') or (Tag = 'input') or (Tag = 'embed') or (Tag = 'audio') or
    (Tag = 'video') or (Tag = 'source') or (Tag = 'track') then
    AddAttributeLink(Links, Attributes, 'src', LinkRequisite)
  else if Tag = 'object' then
    AddAttributeLink(Links, Attributes, 'data', LinkRequisite)
  else if (Tag = 'body') or (Tag = 'table') or (Tag = 'td') or (Tag = 'th') then
    AddAttributeLink(Links, Attributes, 'background', LinkRequisite)
  else if Tag = 'meta' then
    AddRefreshLink(Links, Attributes);
end;

{ Position past the "</Tag" that closes a raw text element (script,
  style), or past the end. }
function SkipRawText(const Html, Tag: string; Position: Integer): Integer;
var
  Found: Integer;
begin
  Found := PosEx('</' + Tag, LowerCase(Html), Position);
  if Found = 0 then
    Result := Length(Html) + 1
  else
    Result := Found;
end;

function ExtractLinks(const Html: string): TFoundLinkArray;
var
  Position, Start: Integer;
  Tag: string;
  Attributes: TAttributeArray;
  Found: Integer;
begin
  Result := nil;
  Position := 1;
  while Position <= Length(Html) do
  begin
    Found := PosEx('<', Html, Position);
    if Found = 0 then
      Break;
    Position := Found + 1;
    if Copy(Html, Position, 3) = '!--' then
    begin
      Found := PosEx('-->', Html, Position + 3);
      if Found = 0 then
        Break;
      Position := Found + 3;
      Continue;
    end;
    Start := Position;
    while (Position <= Length(Html)) and (Html[Position] in NameCharacters) do
      Inc(Position);
    if Position = Start then
      Continue;
    Tag := LowerCase(Copy(Html, Start, Position - Start));
    Attributes := ReadAttributes(Html, Position);
    AddTagLinks(Result, Tag, Attributes);
    if (Tag = 'script') or (Tag = 'style') then
      Position := SkipRawText(Html, Tag, Position);
  end;
end;

function FindBaseReference(const Links: TFoundLinkArray): string;
var
  Index: Integer;
begin
  for Index := 0 to High(Links) do
    if Links[Index].Kind = LinkBase then
      Exit(Links[Index].Reference);
  Result := '';
end;

end.

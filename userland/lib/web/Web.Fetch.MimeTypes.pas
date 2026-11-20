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
  MIME types (MIME Sniffing Standard section 4): parsing with its
  parameter rules (lower case type, subtype and parameter names; quoted
  values; the first of a name wins; bad parameters skipped),
  serializing, the essence, the groups the standards test for (HTML,
  XML, JSON, JavaScript, image, font, scriptable), and Fetch's
  "extract a MIME type" from Content-Type fields (section 3.5), which
  keeps a charset across values of the same essence.
}
unit Web.Fetch.MimeTypes;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TMimeParameter = record
    Name: string;
    Value: string;
  end;

  TMimeType = record
    Valid: Boolean;
    MainType: string;
    SubType: string;
    Parameters: array of TMimeParameter;
  end;

function ParseMimeType(const Input: string): TMimeType;
function SerializeMimeType(constref MimeType: TMimeType): string;
{ "type/subtype", or '' for an invalid one. }
function MimeEssence(constref MimeType: TMimeType): string;
function MimeParameter(constref MimeType: TMimeType; const Name: string; out Value: string): Boolean;
procedure SetMimeParameter(var MimeType: TMimeType; const Name, Value: string);
function MakeMimeType(const Essence: string): TMimeType;

{ Fetch's "extract a MIME type" from every Content-Type value; Valid is
  False when there is none to use. }
function ExtractMimeType(const ContentTypeValues: array of string): TMimeType;

function IsHtmlMimeType(const Essence: string): Boolean;
function IsXmlMimeType(const Essence: string): Boolean;
function IsJsonMimeType(const Essence: string): Boolean;
function IsJavaScriptMimeType(const Essence: string): Boolean;
function IsImageMimeType(const Essence: string): Boolean;
function IsFontMimeType(const Essence: string): Boolean;
function IsCssMimeType(const Essence: string): Boolean;
{ text/plain and the text-like types a browser shows as text. }
function IsTextLikeMimeType(const Essence: string): Boolean;

function IsHttpWhitespace(Character: Char): Boolean; inline;
function IsHttpTokenCodePoint(Character: Char): Boolean;
function TrimHttpWhitespace(const Text: string): string;

implementation

function IsHttpWhitespace(Character: Char): Boolean;
begin
  Result := Character in [#9, #10, #13, ' '];
end;

function IsHttpTokenCodePoint(Character: Char): Boolean;
begin
  Result := Character in ['!', '#', '$', '%', '&', '''', '*', '+', '-', '.', '^', '_', '`', '|', '~', '0'..'9',
    'A'..'Z', 'a'..'z'];
end;

function IsQuotedStringCodePoint(Character: Char): Boolean;
begin
  Result := (Character = #9) or (Character >= ' ') and (Character <> #127) or (Character >= #128);
end;

function TrimHttpWhitespace(const Text: string): string;
var
  First, Last: Integer;
begin
  First := 1;
  Last := Length(Text);
  while (First <= Last) and IsHttpWhitespace(Text[First]) do
    Inc(First);
  while (Last >= First) and IsHttpWhitespace(Text[Last]) do
    Dec(Last);
  Result := Copy(Text, First, Last - First + 1);
end;

function TrimTrailingHttpWhitespace(const Text: string): string;
var
  Last: Integer;
begin
  Last := Length(Text);
  while (Last >= 1) and IsHttpWhitespace(Text[Last]) do
    Dec(Last);
  Result := Copy(Text, 1, Last);
end;

function AllTokenCodePoints(const Text: string): Boolean;
var
  Index: Integer;
begin
  if Text = '' then
    Exit(False);
  for Index := 1 to Length(Text) do
    if not IsHttpTokenCodePoint(Text[Index]) then
      Exit(False);
  Result := True;
end;

function AllQuotedStringCodePoints(const Text: string): Boolean;
var
  Index: Integer;
begin
  for Index := 1 to Length(Text) do
    if not IsQuotedStringCodePoint(Text[Index]) then
      Exit(False);
  Result := True;
end;

{ Fetch's "collect an HTTP quoted string" with the value extracted. }
function CollectQuotedString(const Input: string; var Position: Integer): string;
begin
  Result := '';
  Inc(Position);
  while Position <= Length(Input) do
  begin
    if Input[Position] = '"' then
    begin
      Inc(Position);
      Exit;
    end;
    if Input[Position] = '\' then
    begin
      Inc(Position);
      if Position > Length(Input) then
      begin
        Result := Result + '\';
        Exit;
      end;
    end;
    Result := Result + Input[Position];
    Inc(Position);
  end;
end;

function HasParameter(constref MimeType: TMimeType; const Name: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(MimeType.Parameters) do
    if MimeType.Parameters[Index].Name = Name then
      Exit(True);
  Result := False;
end;

function ParseMimeType(const Input: string): TMimeType;
var
  Text, Name, Value: string;
  Position, Start: Integer;
begin
  Result := Default(TMimeType);
  Text := TrimHttpWhitespace(Input);
  Position := 1;
  Start := Position;
  while (Position <= Length(Text)) and (Text[Position] <> '/') do
    Inc(Position);
  Result.MainType := LowerCase(Copy(Text, Start, Position - Start));
  if not AllTokenCodePoints(Result.MainType) or (Position > Length(Text)) then
    Exit;
  Inc(Position);
  Start := Position;
  while (Position <= Length(Text)) and (Text[Position] <> ';') do
    Inc(Position);
  Result.SubType := LowerCase(TrimHttpWhitespace(Copy(Text, Start, Position - Start)));
  if not AllTokenCodePoints(Result.SubType) then
    Exit;
  Result.Valid := True;
  while Position <= Length(Text) do
  begin
    { Past the ';' and the whitespace after it. }
    Inc(Position);
    while (Position <= Length(Text)) and IsHttpWhitespace(Text[Position]) do
      Inc(Position);
    Start := Position;
    while (Position <= Length(Text)) and not (Text[Position] in [';', '=']) do
      Inc(Position);
    Name := LowerCase(Copy(Text, Start, Position - Start));
    if Position <= Length(Text) then
    begin
      if Text[Position] = ';' then
        Continue;
      Inc(Position);
    end;
    if Position > Length(Text) then
      Break;
    if Text[Position] = '"' then
    begin
      Value := CollectQuotedString(Text, Position);
      while (Position <= Length(Text)) and (Text[Position] <> ';') do
        Inc(Position);
    end
    else
    begin
      Start := Position;
      while (Position <= Length(Text)) and (Text[Position] <> ';') do
        Inc(Position);
      Value := TrimTrailingHttpWhitespace(Copy(Text, Start, Position - Start));
      if Value = '' then
        Continue;
    end;
    if (Name <> '') and AllTokenCodePoints(Name) and AllQuotedStringCodePoints(Value) and
       not HasParameter(Result, Name) then
    begin
      SetLength(Result.Parameters, Length(Result.Parameters) + 1);
      Result.Parameters[High(Result.Parameters)].Name := Name;
      Result.Parameters[High(Result.Parameters)].Value := Value;
    end;
  end;
end;

function SerializeMimeType(constref MimeType: TMimeType): string;
var
  Index, Position: Integer;
  Value, Quoted: string;
begin
  if not MimeType.Valid then
    Exit('');
  Result := MimeType.MainType + '/' + MimeType.SubType;
  for Index := 0 to High(MimeType.Parameters) do
  begin
    Value := MimeType.Parameters[Index].Value;
    if (Value = '') or not AllTokenCodePoints(Value) then
    begin
      Quoted := '"';
      for Position := 1 to Length(Value) do
      begin
        if Value[Position] in ['"', '\'] then
          Quoted := Quoted + '\';
        Quoted := Quoted + Value[Position];
      end;
      Value := Quoted + '"';
    end;
    Result := Result + ';' + MimeType.Parameters[Index].Name + '=' + Value;
  end;
end;

function MimeEssence(constref MimeType: TMimeType): string;
begin
  if not MimeType.Valid then
    Exit('');
  Result := MimeType.MainType + '/' + MimeType.SubType;
end;

function MimeParameter(constref MimeType: TMimeType; const Name: string; out Value: string): Boolean;
var
  Index: Integer;
begin
  Value := '';
  for Index := 0 to High(MimeType.Parameters) do
    if MimeType.Parameters[Index].Name = Name then
    begin
      Value := MimeType.Parameters[Index].Value;
      Exit(True);
    end;
  Result := False;
end;

procedure SetMimeParameter(var MimeType: TMimeType; const Name, Value: string);
var
  Index: Integer;
begin
  for Index := 0 to High(MimeType.Parameters) do
    if MimeType.Parameters[Index].Name = Name then
    begin
      MimeType.Parameters[Index].Value := Value;
      Exit;
    end;
  SetLength(MimeType.Parameters, Length(MimeType.Parameters) + 1);
  MimeType.Parameters[High(MimeType.Parameters)].Name := Name;
  MimeType.Parameters[High(MimeType.Parameters)].Value := Value;
end;

function MakeMimeType(const Essence: string): TMimeType;
begin
  Result := ParseMimeType(Essence);
end;

{ "get, decode, and split": values split at commas outside quotes. }
function SplitValues(const Values: array of string): TStringArray;
var
  Index, Position, Start: Integer;
  Value, Part: string;
begin
  Result := nil;
  for Index := 0 to High(Values) do
  begin
    Value := Values[Index];
    Position := 1;
    Part := '';
    while True do
    begin
      Start := Position;
      while (Position <= Length(Value)) and not (Value[Position] in ['"', ',']) do
        Inc(Position);
      Part := Part + Copy(Value, Start, Position - Start);
      if (Position <= Length(Value)) and (Value[Position] = '"') then
      begin
        Start := Position;
        Inc(Position);
        while (Position <= Length(Value)) and (Value[Position] <> '"') do
        begin
          if (Value[Position] = '\') and (Position < Length(Value)) then
            Inc(Position);
          Inc(Position);
        end;
        if Position <= Length(Value) then
          Inc(Position);
        Part := Part + Copy(Value, Start, Position - Start);
        if Position <= Length(Value) then
          Continue;
      end;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := TrimHttpWhitespace(Part);
      Part := '';
      if Position > Length(Value) then
        Break;
      Inc(Position);
    end;
  end;
end;

function ExtractMimeType(const ContentTypeValues: array of string): TMimeType;
var
  Values: TStringArray;
  Index: Integer;
  Candidate: TMimeType;
  Charset, Essence, CandidateCharset: string;
  HasCharset: Boolean;
begin
  Result := Default(TMimeType);
  Charset := '';
  HasCharset := False;
  Essence := '';
  Values := SplitValues(ContentTypeValues);
  for Index := 0 to High(Values) do
  begin
    Candidate := ParseMimeType(Values[Index]);
    if not Candidate.Valid or (MimeEssence(Candidate) = '*/*') then
      Continue;
    Result := Candidate;
    if MimeEssence(Candidate) <> Essence then
    begin
      HasCharset := MimeParameter(Candidate, 'charset', Charset);
      Essence := MimeEssence(Candidate);
    end
    else if not MimeParameter(Candidate, 'charset', CandidateCharset) and HasCharset then
      SetMimeParameter(Result, 'charset', Charset);
  end;
end;

function IsHtmlMimeType(const Essence: string): Boolean;
begin
  Result := Essence = 'text/html';
end;

function IsXmlMimeType(const Essence: string): Boolean;
begin
  Result := (Essence = 'text/xml') or (Essence = 'application/xml') or
    ((Length(Essence) > 4) and (Copy(Essence, Length(Essence) - 3, 4) = '+xml'));
end;

function IsJsonMimeType(const Essence: string): Boolean;
begin
  Result := (Essence = 'application/json') or (Essence = 'text/json') or
    ((Length(Essence) > 5) and (Copy(Essence, Length(Essence) - 4, 5) = '+json'));
end;

function IsJavaScriptMimeType(const Essence: string): Boolean;
begin
  case Essence of
    'application/ecmascript', 'application/javascript', 'application/x-ecmascript',
    'application/x-javascript', 'text/ecmascript', 'text/javascript', 'text/javascript1.0',
    'text/javascript1.1', 'text/javascript1.2', 'text/javascript1.3', 'text/javascript1.4',
    'text/javascript1.5', 'text/jscript', 'text/livescript', 'text/x-ecmascript', 'text/x-javascript':
      Result := True;
  else
    Result := False;
  end;
end;

function IsImageMimeType(const Essence: string): Boolean;
begin
  Result := Copy(Essence, 1, 6) = 'image/';
end;

function IsFontMimeType(const Essence: string): Boolean;
begin
  if Copy(Essence, 1, 5) = 'font/' then
    Exit(True);
  case Essence of
    'application/font-cff', 'application/font-off', 'application/font-sfnt', 'application/font-ttf',
    'application/font-woff', 'application/vnd.ms-fontobject', 'application/vnd.ms-opentype':
      Result := True;
  else
    Result := False;
  end;
end;

function IsCssMimeType(const Essence: string): Boolean;
begin
  Result := Essence = 'text/css';
end;

function IsTextLikeMimeType(const Essence: string): Boolean;
begin
  if IsHtmlMimeType(Essence) then
    Exit(False);
  Result := (Copy(Essence, 1, 5) = 'text/') or IsJsonMimeType(Essence) or IsJavaScriptMimeType(Essence) or
    IsXmlMimeType(Essence);
end;

end.

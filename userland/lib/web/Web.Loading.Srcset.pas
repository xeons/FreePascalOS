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
  Responsive images (HTML Standard 4.8.4.3): "parse a srcset attribute"
  (URLs with w, x and h descriptors; a candidate with a bad or
  repeated descriptor dropped), "parse a sizes attribute" (the first
  entry whose media condition matches, its length in px, em, rem, ex,
  ch, vw, vh, vmin or vmax; 100vw by default), and "select an image
  source": the img's src as a 1x candidate when there are no width
  descriptors, densities of width descriptors from the source size,
  then the smallest density at least the device pixel ratio (else the
  largest). <picture> sources come first: the first <source> with a
  srcset whose media matches and whose type is one libimage decodes.
}
unit Web.Loading.Srcset;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Css.MediaQueries,
  Web.Dom;

type
  TImageCandidate = record
    Url: string;
    Density: Double;
    HasWidth: Boolean;
    Width: Integer;
    HasDensity: Boolean;
  end;

  TImageCandidateArray = array of TImageCandidate;

  TImageSourceChoice = record
    Found: Boolean;
    Url: string;
    Density: Double;
    { The source size in CSS pixels when width descriptors were used. }
    SourceSize: Double;
  end;

function ParseSrcset(const Text: string): TImageCandidateArray;
{ The source size in CSS pixels. }
function ParseSizes(const Text: string; constref Environment: TCssMediaEnvironment): Double;
function SelectImageCandidate(const Candidates: TImageCandidateArray; const Src: string; SourceSize: Double;
  DevicePixelRatio: Double): TImageSourceChoice;
{ The whole choice for an img element (its picture parent included). }
function SelectImageSource(Image: TElement; constref Environment: TCssMediaEnvironment): TImageSourceChoice;
{ An image MIME type libimage can decode. }
function IsSupportedImageType(const MimeType: string): Boolean;

implementation

uses
  Web.Atoms,
  Web.Fetch.MimeTypes;

function IsSpace(Character: Char): Boolean; inline;
begin
  Result := Character in [#9, #10, #12, #13, ' '];
end;

function AllDigits(const Text: string): Boolean;
var
  Index: Integer;
begin
  if (Text = '') or (Length(Text) > 9) then
    Exit(False);
  for Index := 1 to Length(Text) do
    if not (Text[Index] in ['0'..'9']) then
      Exit(False);
  Result := True;
end;

function ParseDescriptors(const Descriptors: array of string; var Candidate: TImageCandidate): Boolean;
var
  Index, Code: Integer;
  Descriptor, Number: string;
  Last: Char;
  Value: Double;
  HasHeight: Boolean;
begin
  Result := True;
  HasHeight := False;
  for Index := 0 to High(Descriptors) do
  begin
    Descriptor := Descriptors[Index];
    if Descriptor = '' then
      Continue;
    Last := LowerCase(Descriptor[Length(Descriptor)]);
    Number := Copy(Descriptor, 1, Length(Descriptor) - 1);
    if (Last = 'w') or (Last = 'h') then
    begin
      if not AllDigits(Number) or (StrToIntDef(Number, 0) <= 0) then
        Exit(False);
      if Last = 'w' then
      begin
        if Candidate.HasWidth or Candidate.HasDensity then
          Exit(False);
        Candidate.HasWidth := True;
        Candidate.Width := StrToInt(Number);
      end
      else
      begin
        if HasHeight or Candidate.HasDensity then
          Exit(False);
        HasHeight := True;
      end;
    end
    else if Last = 'x' then
    begin
      Val(Number, Value, Code);
      if (Number = '') or (Code <> 0) or (Value < 0) or Candidate.HasWidth or Candidate.HasDensity or HasHeight then
        Exit(False);
      Candidate.HasDensity := True;
      Candidate.Density := Value;
    end
    else
      Exit(False);
  end;
  if HasHeight and not Candidate.HasWidth then
    Exit(False);
end;

function ParseSrcset(const Text: string): TImageCandidateArray;
var
  Position, Start: Integer;
  Url, Current: string;
  Descriptors: array of string;
  InParens: Boolean;
  Candidate: TImageCandidate;
begin
  Result := nil;
  Position := 1;
  while True do
  begin
    while (Position <= Length(Text)) and (IsSpace(Text[Position]) or (Text[Position] = ',')) do
      Inc(Position);
    if Position > Length(Text) then
      Exit;
    Start := Position;
    while (Position <= Length(Text)) and not IsSpace(Text[Position]) do
      Inc(Position);
    Url := Copy(Text, Start, Position - Start);
    Descriptors := nil;
    if (Url <> '') and (Url[Length(Url)] = ',') then
    begin
      while (Url <> '') and (Url[Length(Url)] = ',') do
        SetLength(Url, Length(Url) - 1);
    end
    else
    begin
      { The descriptor tokenizer. }
      while (Position <= Length(Text)) and IsSpace(Text[Position]) do
        Inc(Position);
      Current := '';
      InParens := False;
      while Position <= Length(Text) do
      begin
        if InParens then
        begin
          if Text[Position] = ')' then
            InParens := False;
          Current := Current + Text[Position];
        end
        else if IsSpace(Text[Position]) then
        begin
          if Current <> '' then
          begin
            SetLength(Descriptors, Length(Descriptors) + 1);
            Descriptors[High(Descriptors)] := Current;
            Current := '';
          end;
        end
        else if Text[Position] = ',' then
        begin
          Inc(Position);
          Break;
        end
        else
        begin
          if Text[Position] = '(' then
            InParens := True;
          Current := Current + Text[Position];
        end;
        Inc(Position);
      end;
      if Current <> '' then
      begin
        SetLength(Descriptors, Length(Descriptors) + 1);
        Descriptors[High(Descriptors)] := Current;
      end;
    end;
    Candidate := Default(TImageCandidate);
    Candidate.Url := Url;
    Candidate.Density := 1;
    if (Url <> '') and ParseDescriptors(Descriptors, Candidate) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Candidate;
    end;
  end;
end;

function LengthInPixels(const Text: string; constref Environment: TCssMediaEnvironment; out Pixels: Double): Boolean;
var
  Position, Code: Integer;
  Number, LengthUnit: string;
  Value: Double;
begin
  Position := 1;
  while (Position <= Length(Text)) and (Text[Position] in ['0'..'9', '.', '-', '+', 'e', 'E']) do
  begin
    { An "e" is an exponent only when a digit follows. }
    if (Text[Position] in ['e', 'E']) and
       not ((Position < Length(Text)) and (Text[Position + 1] in ['0'..'9', '-', '+'])) then
      Break;
    Inc(Position);
  end;
  Number := Copy(Text, 1, Position - 1);
  LengthUnit := LowerCase(Copy(Text, Position, MaxInt));
  Val(Number, Value, Code);
  if (Number = '') or (Code <> 0) or (Value < 0) then
    Exit(False);
  Result := True;
  case LengthUnit of
    'px': Pixels := Value;
    'em', 'rem': Pixels := Value * 16;
    'ex', 'ch': Pixels := Value * 8;
    'vw': Pixels := Value * Environment.Width / 100;
    'vh': Pixels := Value * Environment.Height / 100;
    'vmin':
      if Environment.Width < Environment.Height then
        Pixels := Value * Environment.Width / 100
      else
        Pixels := Value * Environment.Height / 100;
    'vmax':
      if Environment.Width > Environment.Height then
        Pixels := Value * Environment.Width / 100
      else
        Pixels := Value * Environment.Height / 100;
    '':
      begin
        Pixels := 0;
        Result := Value = 0;
      end;
  else
    Result := False;
  end;
end;

function ParseSizes(const Text: string; constref Environment: TCssMediaEnvironment): Double;
var
  Entries: TStringArray;
  Index, Split, Depth, Position: Integer;
  Entry, Condition, SizeText: string;
  Media: TCssMediaQueryList;
  Matches: Boolean;
  Pixels: Double;
begin
  Entries := Text.Split([',']);
  for Index := 0 to High(Entries) do
  begin
    Entry := Trim(Entries[Index]);
    if Entry = '' then
      Continue;
    { The size is the last component value (outside parentheses). }
    Split := 0;
    Depth := 0;
    for Position := 1 to Length(Entry) do
      if Entry[Position] = '(' then
        Inc(Depth)
      else if Entry[Position] = ')' then
        Dec(Depth)
      else if (Depth = 0) and IsSpace(Entry[Position]) then
        Split := Position;
    if Split = 0 then
    begin
      Condition := '';
      SizeText := Entry;
    end
    else
    begin
      Condition := Trim(Copy(Entry, 1, Split - 1));
      SizeText := Trim(Copy(Entry, Split + 1, MaxInt));
    end;
    if not LengthInPixels(SizeText, Environment, Pixels) then
      Continue;
    if AsciiLowerCase(SizeText) = 'auto' then
      Continue;
    Matches := True;
    if Condition <> '' then
    begin
      Media := ParseMediaQueryText(Condition);
      try
        Matches := (Media <> nil) and Media.Matches(Environment);
      finally
        Media.Free;
      end;
    end;
    if Matches then
      Exit(Pixels);
  end;
  Result := Environment.Width;
end;

function SelectImageCandidate(const Candidates: TImageCandidateArray; const Src: string; SourceSize: Double;
  DevicePixelRatio: Double): TImageSourceChoice;
var
  List: TImageCandidateArray;
  Index, Best: Integer;
  HasWidths, HasOneX: Boolean;
begin
  Result := Default(TImageSourceChoice);
  Result.SourceSize := SourceSize;
  List := Copy(Candidates);
  HasWidths := False;
  HasOneX := False;
  for Index := 0 to High(List) do
  begin
    if List[Index].HasWidth then
    begin
      HasWidths := True;
      if SourceSize > 0 then
        List[Index].Density := List[Index].Width / SourceSize
      else
        List[Index].Density := List[Index].Width;
    end
    else if List[Index].Density = 1 then
      HasOneX := True;
  end;
  if (Src <> '') and not HasWidths and not HasOneX then
  begin
    SetLength(List, Length(List) + 1);
    List[High(List)] := Default(TImageCandidate);
    List[High(List)].Url := Src;
    List[High(List)].Density := 1;
  end;
  if Length(List) = 0 then
    Exit;
  if DevicePixelRatio <= 0 then
    DevicePixelRatio := 1;
  Best := -1;
  for Index := 0 to High(List) do
    if (List[Index].Density >= DevicePixelRatio) and
       ((Best < 0) or (List[Index].Density < List[Best].Density)) then
      Best := Index;
  if Best < 0 then
    for Index := 0 to High(List) do
      if (Best < 0) or (List[Index].Density > List[Best].Density) then
        Best := Index;
  Result.Found := True;
  Result.Url := List[Best].Url;
  Result.Density := List[Best].Density;
  if Result.Density <= 0 then
    Result.Density := 1;
end;

function IsSupportedImageType(const MimeType: string): Boolean;
begin
  case AsciiLowerCase(TrimHttpWhitespace(MimeType)) of
    'image/png', 'image/apng', 'image/jpeg', 'image/pjpeg', 'image/gif', 'image/webp', 'image/bmp',
    'image/x-icon', 'image/vnd.microsoft.icon', 'image/tiff', 'image/jxl':
      Result := True;
  else
    Result := False;
  end;
end;

function SourceMatches(Source: TElement; constref Environment: TCssMediaEnvironment): Boolean;
var
  Media: TCssMediaQueryList;
begin
  if not Source.HasAttributeAtom(AtomSrcset) then
    Exit(False);
  if Source.HasAttributeAtom(AtomMedia) and (Trim(Source.AttributeValueOf(AtomMedia)) <> '') then
  begin
    Media := ParseMediaQueryText(Source.AttributeValueOf(AtomMedia));
    try
      if (Media <> nil) and not Media.Matches(Environment) then
        Exit(False);
    finally
      Media.Free;
    end;
  end;
  if Source.HasAttributeAtom(AtomType) and (Trim(Source.AttributeValueOf(AtomType)) <> '') and
     not IsSupportedImageType(MimeEssence(ParseMimeType(Source.AttributeValueOf(AtomType)))) then
    Exit(False);
  Result := True;
end;

function SelectImageSource(Image: TElement; constref Environment: TCssMediaEnvironment): TImageSourceChoice;
var
  Parent: TElement;
  Node: TNode;
  Source: TElement;
  Size: Double;
begin
  Parent := Image.ParentElement;
  if (Parent <> nil) and Parent.IsHtmlElement(AtomPicture) then
  begin
    Node := Parent.FirstChild;
    while (Node <> nil) and (Node <> Image) do
    begin
      if Node.IsElement and TElement(Node).IsHtmlElement(AtomSource) then
      begin
        Source := TElement(Node);
        if SourceMatches(Source, Environment) then
        begin
          Size := ParseSizes(Source.AttributeValueOf(AtomSizes), Environment);
          Result := SelectImageCandidate(ParseSrcset(Source.AttributeValueOf(AtomSrcset)), '', Size,
            Environment.Resolution);
          if Result.Found then
            Exit;
        end;
      end;
      Node := Node.NextSibling;
    end;
  end;
  Size := ParseSizes(Image.AttributeValueOf(AtomSizes), Environment);
  Result := SelectImageCandidate(ParseSrcset(Image.AttributeValueOf(AtomSrcset)),
    Image.AttributeValueOf(AtomSrc), Size, Environment.Resolution);
end;

end.

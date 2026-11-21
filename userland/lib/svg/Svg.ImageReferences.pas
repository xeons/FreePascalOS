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
  Pictures an SVG <image> refers to: data: URLs (base64 or percent
  encoded), decoded once by libimage (any format it reads, SVG too when
  its codec is registered) and kept with the document. Other URLs are
  not fetched: an SVG shown as an image may not load anything, and an
  embedder resolving them is still to come.
}
unit Svg.ImageReferences;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Image.Model;

type
  TSvgImageCache = class
  private
    FReferences: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    { The decoded picture (kept by the cache), nil when it cannot be had. }
    function ImageFor(const Reference: string): TImage;
  end;

{ The bytes of a data: URL; False when Url is not one. }
function DecodeDataUrl(const Url: string; out Data: TBytes): Boolean;

implementation

uses
  Image.Errors,
  Image.Files,
  { SVG pictures inside SVG: its codec registered. }
  Svg.Images;

const
  MaximumImages = 64;

function Base64Value(Character: Char): Integer;
begin
  case Character of
    'A'..'Z': Result := Ord(Character) - Ord('A');
    'a'..'z': Result := Ord(Character) - Ord('a') + 26;
    '0'..'9': Result := Ord(Character) - Ord('0') + 52;
    '+', '-': Result := 62;
    '/', '_': Result := 63;
    else
      Result := -1;
  end;
end;

function DecodeBase64(const Text: string): TBytes;
var
  Index: Integer;
  Value: Integer;
  Accumulator: LongWord;
  Bits: Integer;
  Count: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Text) * 3 div 4 + 3);
  Count := 0;
  Accumulator := 0;
  Bits := 0;
  for Index := 1 to Length(Text) do
  begin
    Value := Base64Value(Text[Index]);
    if Value < 0 then
      Continue;
    Accumulator := ((Accumulator shl 6) or LongWord(Value)) and $FFFFFF;
    Inc(Bits, 6);
    if Bits >= 8 then
    begin
      Dec(Bits, 8);
      Result[Count] := Byte(Accumulator shr Bits);
      Inc(Count);
    end;
  end;
  SetLength(Result, Count);
end;

function HexDigit(Character: Char): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
    else
      Result := -1;
  end;
end;

function DecodePercent(const Text: string): TBytes;
var
  Index: Integer;
  Count: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Text));
  Count := 0;
  Index := 1;
  while Index <= Length(Text) do
  begin
    if (Text[Index] = '%') and (Index + 2 <= Length(Text)) and (HexDigit(Text[Index + 1]) >= 0) and
       (HexDigit(Text[Index + 2]) >= 0) then
    begin
      Result[Count] := HexDigit(Text[Index + 1]) * 16 + HexDigit(Text[Index + 2]);
      Inc(Index, 3);
    end
    else
    begin
      Result[Count] := Ord(Text[Index]);
      Inc(Index);
    end;
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

function DecodeDataUrl(const Url: string; out Data: TBytes): Boolean;
var
  Comma: Integer;
  Header: string;
begin
  Data := nil;
  if LowerCase(Copy(Url, 1, 5)) <> 'data:' then
    Exit(False);
  Comma := Pos(',', Url);
  if Comma = 0 then
    Exit(False);
  Header := LowerCase(Copy(Url, 6, Comma - 6));
  if (Length(Header) >= 7) and (Copy(Header, Length(Header) - 6, 7) = ';base64') then
    Data := DecodeBase64(Copy(Url, Comma + 1, Length(Url)))
  else
    Data := DecodePercent(Copy(Url, Comma + 1, Length(Url)));
  Result := Length(Data) > 0;
end;

constructor TSvgImageCache.Create;
begin
  inherited Create;
  FReferences := TStringList.Create;
  FReferences.CaseSensitive := True;
  FReferences.OwnsObjects := True;
end;

destructor TSvgImageCache.Destroy;
begin
  FReferences.Free;
  inherited Destroy;
end;

function TSvgImageCache.ImageFor(const Reference: string): TImage;
var
  Index: Integer;
  Data: TBytes;
  Image: TImage;
  Reason: TImageErrorReason;
begin
  Index := FReferences.IndexOf(Reference);
  if Index >= 0 then
    Exit(TImage(FReferences.Objects[Index]));
  Image := nil;
  if (FReferences.Count < MaximumImages) and DecodeDataUrl(Reference, Data) then
    if not TryLoadImage(Data, Image, Reason, [ImageLoadApplyOrientation, ImageLoadConvertToSrgb]) then
      Image := nil;
  FReferences.AddObject(Reference, Image);
  Result := Image;
end;

end.

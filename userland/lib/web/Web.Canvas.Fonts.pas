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
  The canvas font (HTML Standard 4.12.5.1.4, the font attribute): the
  CSS font shorthand parsed with libcss (CSS-wide keywords and var() are
  not allowed and leave the font as it was), sizes resolved to pixels
  (relative ones against 10px, the size of a canvas without a computed
  font), and the face chosen through libweb's text fonts. Fonts are kept
  in a small cache by what they are made from, since pages set the same
  font again and again. The serialization omits line-height and the
  values at their initial state, as browsers do.
}
unit Web.Canvas.Fonts;

{$mode objfpc}
{$H+}

interface

uses
  Web.Text.FontInstances;

type
  TCanvasFont = record
    { As font returns it. }
    Text: string;
    Families: array of string;
    Size: Double;
    Weight: Integer;
    Italic: Boolean;
    SmallCaps: Boolean;
    Stretch: string;
    { The face's metrics and glyphs at Size (from the cache). }
    Font: TTextFont;
  end;

const
  DefaultCanvasFontText = '10px sans-serif';
  { The size relative font sizes are resolved against. }
  CanvasBaseFontSize = 10;

{ Text as a CSS font value; False (Font untouched) when it is not one. }
function ParseCanvasFont(const Text: string; var Font: TCanvasFont): Boolean;
function DefaultCanvasFont: TCanvasFont;

implementation

uses
  SysUtils,
  Css.Tokens,
  Css.Tokenizer,
  Css.Values,
  Css.Keywords,
  Css.Units,
  Css.PropertyIds,
  Css.Declarations;

const
  FontCacheCapacity = 64;

type
  TFontCacheEntry = record
    Key: string;
    Font: TTextFont;
  end;

var
  FontCache: array of TFontCacheEntry;
  FontCacheNext: Integer;

function CachedFont(const Families: array of string; Size: Double; Weight: Integer; Italic: Boolean): TTextFont;
var
  Key: string;
  Index: Integer;
begin
  Key := FloatToStr(Size) + '/' + IntToStr(Weight) + '/' + BoolToStr(Italic, True);
  for Index := 0 to High(Families) do
    Key := Key + '/' + Families[Index];
  for Index := 0 to High(FontCache) do
    if FontCache[Index].Key = Key then
      Exit(FontCache[Index].Font);
  Result := MakeTextFont(Families, Size, Weight, Italic);
  if Length(FontCache) < FontCacheCapacity then
  begin
    SetLength(FontCache, Length(FontCache) + 1);
    Index := High(FontCache);
  end
  else
  begin
    Index := FontCacheNext;
    FontCacheNext := (FontCacheNext + 1) mod FontCacheCapacity;
  end;
  FontCache[Index].Key := Key;
  FontCache[Index].Font := Result;
end;

function KeywordSize(Keyword: TCssKeyword; out Size: Double): Boolean;
begin
  Result := True;
  case Keyword of
    kwXxSmall: Size := 9;
    kwXSmall: Size := 10;
    kwSmall: Size := 13;
    kwMedium: Size := 16;
    kwLarge: Size := 18;
    kwXLarge: Size := 24;
    kwXxLarge: Size := 32;
    kwXxxLarge: Size := 48;
    kwLarger: Size := CanvasBaseFontSize * 1.2;
    kwSmaller: Size := CanvasBaseFontSize / 1.2;
  else
    Result := False;
  end;
end;

function SizeInPixels(Value: TCssValue; out Size: Double): Boolean;
begin
  Result := False;
  Size := 0;
  if Value = nil then
    Exit;
  case Value.Kind of
    vkKeyword:
      Result := KeywordSize(Value.Keyword, Size);
    vkPercentage:
      begin
        Size := CanvasBaseFontSize * Value.Number / 100;
        Result := True;
      end;
    vkDimension:
      begin
        if IsAbsoluteLength(Value.UnitValue) then
          Size := Value.Number * CanonicalFactor(Value.UnitValue)
        else
          case Value.UnitValue of
            cuEm, cuRem, cuLh, cuRlh, cuCap, cuRcap, cuIc, cuRic:
              Size := Value.Number * CanvasBaseFontSize;
            cuEx, cuRex, cuCh, cuRch:
              Size := Value.Number * CanvasBaseFontSize / 2;
          else
            Exit;
          end;
        Result := True;
      end;
    vkNumber, vkInteger:
      if Value.Number = 0 then
      begin
        Size := 0;
        Result := True;
      end;
  end;
  if Size < 0 then
    Result := False;
end;

function WeightOf(Value: TCssValue; out Weight: Integer): Boolean;
begin
  Weight := 400;
  Result := True;
  if Value = nil then
    Exit;
  case Value.Kind of
    vkNumber, vkInteger:
      Weight := Round(Value.Number);
    vkKeyword:
      case Value.Keyword of
        kwNormal: Weight := 400;
        kwBold: Weight := 700;
        kwBolder: Weight := 700;
        kwLighter: Weight := 100;
      else
        Result := False;
      end;
  else
    Result := False;
  end;
end;

function IsPlainIdentifier(const Name: string): Boolean;
var
  Index: Integer;
begin
  if Name = '' then
    Exit(False);
  if Name[1] in ['0'..'9'] then
    Exit(False);
  for Index := 1 to Length(Name) do
    if not (Name[Index] in ['a'..'z', 'A'..'Z', '0'..'9', '-', '_']) and (Ord(Name[Index]) < 128) then
      Exit(False);
  Result := True;
end;

function FamilyText(Item: TCssValue; out Name, Written: string): Boolean;
begin
  Result := True;
  case Item.Kind of
    vkKeyword:
      begin
        Name := KeywordName(Item.Keyword);
        Written := Name;
      end;
    vkString, vkCustomIdent:
      begin
        Name := Item.Text;
        if IsPlainIdentifier(Name) and (Item.Kind = vkCustomIdent) or IsPlainIdentifier(Name) and
           (Pos(' ', Name) = 0) then
          Written := Name
        else
          Written := '"' + StringReplace(Name, '"', '\"', [rfReplaceAll]) + '"';
      end;
  else
    Result := False;
  end;
end;

function SizeText(Size: Double): string;
begin
  Result := FormatFloat('0.###', Size, DefaultFormatSettings) + 'px';
end;

function DefaultCanvasFont: TCanvasFont;
begin
  Result := Default(TCanvasFont);
  ParseCanvasFont(DefaultCanvasFontText, Result);
end;

function ParseCanvasFont(const Text: string; var Font: TCanvasFont): Boolean;
var
  Block: TCssDeclarationBlock;
  Tokens: TCssTokenArray;
  Declaration: PCssDeclaration;
  Index: Integer;
  Parsed: TCanvasFont;
  Value, Item: TCssValue;
  Name, Written, FamilyList, Prefix: string;
begin
  Result := False;
  Tokens := TokenizeCss(Text);
  for Index := 0 to High(Tokens) do
    if (Tokens[Index].Kind = tkFunction) and ((LowerCase(Tokens[Index].Text) = 'var') or
       (LowerCase(Tokens[Index].Text) = 'env')) then
      Exit;
  Block := TCssDeclarationBlock.Create;
  try
    if not Block.AddParsed('font', TCssTokenCursor.Create(Tokens), False) then
      Exit;
    Parsed := Default(TCanvasFont);
    Parsed.Weight := 400;
    Declaration := Block.Find(cpFontSize);
    if (Declaration = nil) or not SizeInPixels(Declaration^.Value, Parsed.Size) then
      Exit;
    Declaration := Block.Find(cpFontWeight);
    if Declaration <> nil then
      if not WeightOf(Declaration^.Value, Parsed.Weight) then
        Exit;
    Declaration := Block.Find(cpFontStyle);
    if Declaration <> nil then
    begin
      Value := Declaration^.Value;
      if (Value.Kind = vkKeyword) and (Value.Keyword in [kwItalic, kwOblique]) then
        Parsed.Italic := True
      else if (Value.Kind = vkList) and (Value.Count > 0) and Value.Items[0].IsKeyword(kwOblique) then
        Parsed.Italic := True
      else if not Value.IsKeyword(kwNormal) then
        Exit;
    end;
    Declaration := Block.Find(cpFontVariantCaps);
    if Declaration <> nil then
      Parsed.SmallCaps := Declaration^.Value.IsKeyword(kwSmallCaps);
    Declaration := Block.Find(cpFontStretch);
    if (Declaration <> nil) and (Declaration^.Value.Kind = vkKeyword) and
       not Declaration^.Value.IsKeyword(kwNormal) then
      Parsed.Stretch := KeywordName(Declaration^.Value.Keyword);
    Declaration := Block.Find(cpFontFamily);
    if (Declaration = nil) or (Declaration^.Value.Kind <> vkList) then
      Exit;
    FamilyList := '';
    for Index := 0 to Declaration^.Value.Count - 1 do
    begin
      Item := Declaration^.Value.Items[Index];
      if not FamilyText(Item, Name, Written) then
        Exit;
      SetLength(Parsed.Families, Length(Parsed.Families) + 1);
      Parsed.Families[High(Parsed.Families)] := Name;
      if FamilyList <> '' then
        FamilyList := FamilyList + ', ';
      FamilyList := FamilyList + Written;
    end;
    if Length(Parsed.Families) = 0 then
      Exit;
    Prefix := '';
    if Parsed.Italic then
      Prefix := Prefix + 'italic ';
    if Parsed.SmallCaps then
      Prefix := Prefix + 'small-caps ';
    if Parsed.Weight = 700 then
      Prefix := Prefix + 'bold '
    else if Parsed.Weight <> 400 then
      Prefix := Prefix + IntToStr(Parsed.Weight) + ' ';
    if Parsed.Stretch <> '' then
      Prefix := Prefix + Parsed.Stretch + ' ';
    Parsed.Text := Prefix + SizeText(Parsed.Size) + ' ' + FamilyList;
    Parsed.Font := CachedFont(Parsed.Families, Parsed.Size, Parsed.Weight, Parsed.Italic);
    Font := Parsed;
    Result := True;
  finally
    Block.Free;
  end;
end;

end.

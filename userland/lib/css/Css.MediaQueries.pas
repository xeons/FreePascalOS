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
  Media queries (Media Queries Level 4 and 5): parsing, the range
  syntax, serialization, and evaluation against an environment the
  host fills in (viewport size in CSS pixels, resolution, which follows
  the system's DPI scale, color scheme, motion and contrast
  preferences, pointer and hover capabilities, ...).

  Evaluation uses three-valued logic: a condition the engine does not
  understand is "unknown", which counts as false at the top.
}
unit Css.MediaQueries;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens, Css.Keywords, Css.Values;

type
  TCssMediaEnvironment = record
    { kwScreen or kwPrint }
    MediaType: TCssKeyword;
    { The viewport in CSS pixels. }
    Width, Height: Double;
    DeviceWidth, DeviceHeight: Double;
    { Device pixels per CSS pixel (the DPI scale). }
    Resolution: Double;
    { Bits per color component; 0 for monochrome devices. }
    ColorBits: Integer;
    MonochromeBits: Integer;
    DarkColorScheme: Boolean;
    ReducedMotion: Boolean;
    ReducedTransparency: Boolean;
    ReducedData: Boolean;
    { kwNoPreference, kwMore, kwLess or kwCustom }
    Contrast: TCssKeyword;
    ForcedColors: Boolean;
    InvertedColors: Boolean;
    { kwHover or kwNone }
    Hover, AnyHover: TCssKeyword;
    { kwFine, kwCoarse or kwNone }
    Pointer, AnyPointer: TCssKeyword;
    { kwEnabled, kwInitialOnly or kwNone }
    Scripting: TCssKeyword;
    { kwBrowser, kwFullscreen, kwStandalone, kwMinimalUi, kwPictureInPicture }
    DisplayMode: TCssKeyword;
    { kwSrgb, kwP3 or kwRec2020 }
    ColorGamut: TCssKeyword;
    { kwStandard or kwHigh }
    DynamicRange: TCssKeyword;
    { kwFast, kwSlow or kwNone }
    Update: TCssKeyword;
    { The initial font size, what em means in a media query. }
    FontSize: Double;
    { Text zoom (a browser's "zoom text only"): what absolute font sizes
      are multiplied by, lengths and media features staying; 0 or 1
      for none. }
    TextZoom: Double;
  end;

  TCssMediaConditionKind = (mcAnd, mcOr, mcNot, mcFeature, mcUnknown);
  TCssRangeOperator = (roNone, roEqual, roLess, roLessEqual, roGreater, roGreaterEqual);

  TCssMediaCondition = class
  public
    Kind: TCssMediaConditionKind;
    Children: array of TCssMediaCondition;
    { A feature: its lowercase name (without min-/max-), and up to two
      comparisons: "Value1 Op1 name" and "name Op2 Value2". A boolean
      feature has neither. }
    Name: string;
    Op1, Op2: TCssRangeOperator;
    Value1, Value2: TCssValue;
    { The source text of an unknown part (general enclosed). }
    Text: string;
    { How the feature was written: "min-width: 10px" is kept for serialization. }
    WrittenPrefix: string;
    destructor Destroy; override;
    function Serialize(TopLevel: Boolean): string;
  end;

  TCssMediaQuery = record
    Negated: Boolean;
    Only: Boolean;
    { Lowercase media type, '' when the query is only a condition. }
    MediaType: string;
    Condition: TCssMediaCondition;
    { A query that did not parse: "not all". }
    Invalid: Boolean;
  end;

  TCssMediaQueryList = class
  public
    Queries: array of TCssMediaQuery;
    destructor Destroy; override;
    { True for an empty list. }
    function Matches(const Environment: TCssMediaEnvironment): Boolean;
    function Serialize: string;
    function Count: Integer;
  end;

  TCssTriState = (tsFalse, tsTrue, tsUnknown);

function ParseMediaQueryList(Cursor: TCssTokenCursor): TCssMediaQueryList;
function ParseMediaQueryText(const Text: string): TCssMediaQueryList;
{ A condition alone, as @container and @import supports() need. }
function ParseMediaCondition(var Cursor: TCssTokenCursor; AllowOr: Boolean): TCssMediaCondition;
function EvaluateMediaCondition(Condition: TCssMediaCondition; const Environment: TCssMediaEnvironment): TCssTriState;
{ A desktop screen: 1280x800, 96 DPI, light scheme, fine pointer with hover. }
function DefaultMediaEnvironment: TCssMediaEnvironment;

implementation

uses
  SysUtils, Math, Css.Atoms, Css.Units, Css.Calc, Css.Tokenizer, Css.ValueParser, Css.Serialization;

destructor TCssMediaCondition.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Children) do
    Children[Index].Free;
  ReleaseValue(Value1);
  ReleaseValue(Value2);
  inherited Destroy;
end;

function OperatorText(Op: TCssRangeOperator): string;
begin
  case Op of
    roEqual: Result := '=';
    roLess: Result := '<';
    roLessEqual: Result := '<=';
    roGreater: Result := '>';
    roGreaterEqual: Result := '>=';
  else
    Result := '';
  end;
end;

function TCssMediaCondition.Serialize(TopLevel: Boolean): string;
var
  Index: Integer;
  Glue: string;
begin
  case Kind of
    mcFeature:
      begin
        if (Op1 = roNone) and (Op2 = roNone) then
          Result := '(' + Name + ')'
        else if WrittenPrefix <> '' then
          Result := '(' + WrittenPrefix + Name + ': ' + Value2.Serialize + ')'
        else if (Op1 = roNone) and (Op2 = roEqual) then
          Result := '(' + Name + ': ' + Value2.Serialize + ')'
        else
        begin
          Result := '(';
          if Op1 <> roNone then
            Result := Result + Value1.Serialize + ' ' + OperatorText(Op1) + ' ';
          Result := Result + Name;
          if Op2 <> roNone then
            Result := Result + ' ' + OperatorText(Op2) + ' ' + Value2.Serialize;
          Result := Result + ')';
        end;
      end;
    mcUnknown: Result := Text;
    mcNot:
      begin
        Result := 'not ' + Children[0].Serialize(False);
        if not TopLevel then
          Result := '(' + Result + ')';
      end;
  else
    if Kind = mcAnd then
      Glue := ' and '
    else
      Glue := ' or ';
    Result := '';
    for Index := 0 to High(Children) do
    begin
      if Index > 0 then
        Result := Result + Glue;
      Result := Result + Children[Index].Serialize(False);
    end;
    if not TopLevel then
      Result := '(' + Result + ')';
  end;
end;

destructor TCssMediaQueryList.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Queries) do
    Queries[Index].Condition.Free;
  inherited Destroy;
end;

function TCssMediaQueryList.Count: Integer;
begin
  Result := Length(Queries);
end;

function TCssMediaQueryList.Serialize: string;
var
  Index: Integer;
  Query: ^TCssMediaQuery;
  Text: string;
begin
  Result := '';
  for Index := 0 to High(Queries) do
  begin
    Query := @Queries[Index];
    if Query^.Invalid then
      Text := 'not all'
    else
    begin
      Text := '';
      if Query^.Negated then
        Text := 'not '
      else if Query^.Only then
        Text := 'only ';
      if Query^.MediaType <> '' then
      begin
        Text := Text + Query^.MediaType;
        if Query^.Condition <> nil then
          Text := Text + ' and ' + Query^.Condition.Serialize(Query^.Condition.Kind <> mcOr);
      end
      else if Query^.Condition <> nil then
        Text := Text + Query^.Condition.Serialize(True);
    end;
    if Index > 0 then
      Result := Result + ', ';
    Result := Result + Text;
  end;
end;

{ ---- parsing ---- }

function ParseFeatureValue(var Cursor: TCssTokenCursor): TCssValue;
var
  Saved: Integer;
  Token: PCssToken;
  First, Second: TCssValue;
  UnitValue: TCssUnit;
begin
  Result := nil;
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  case Token^.Kind of
    tkNumber:
      begin
        First := ParseNumber(Cursor);
        if SkipDelim(Cursor, '/') then
        begin
          Second := ParseNumber(Cursor, True);
          if Second = nil then
          begin
            First.Release;
            Cursor.Position := Saved;
            Exit;
          end;
          Exit(NewListOf(lsSlash, [First, Second]));
        end;
        Exit(First);
      end;
    tkDimension:
      begin
        UnitValue := UnitByName(Token^.Text);
        if UnitValue = cuNone then
          Exit;
        Inc(Cursor.Position);
        Exit(NewDimension(Token^.Number, UnitValue));
      end;
    tkIdent:
      begin
        Inc(Cursor.Position);
        Exit(NewCustomIdent(AsciiLowercase(Token^.Text)));
      end;
    tkFunction:
      for UnitValue in [cuNone, cuPx, cuDppx] do
      begin
        Result := ParseDimension(Cursor, UnitCategory(UnitValue), False, False, False);
        if (Result = nil) and (UnitValue = cuNone) then
          Result := ParseNumber(Cursor);
        if Result <> nil then
          Exit;
      end;
  end;
  Cursor.Position := Saved;
end;

function ParseOperator(var Cursor: TCssTokenCursor; out Op: TCssRangeOperator): Boolean;
var
  Saved: Integer;
  Token: PCssToken;
begin
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  Result := False;
  Op := roNone;
  if Token^.Kind <> tkDelim then
    Exit;
  if Token^.Text = '=' then
    Op := roEqual
  else if Token^.Text = '<' then
    Op := roLess
  else if Token^.Text = '>' then
    Op := roGreater
  else
    Exit;
  Inc(Cursor.Position);
  { "<=" and ">=" are two tokens with nothing between them. }
  if (Op <> roEqual) and IsDelimToken(Cursor.Peek, '=') then
  begin
    Inc(Cursor.Position);
    if Op = roLess then Op := roLessEqual else Op := roGreaterEqual;
  end;
  Result := True;
  if not Result then
    Cursor.Position := Saved;
end;

function Flip(Op: TCssRangeOperator): TCssRangeOperator;
begin
  case Op of
    roLess: Result := roGreater;
    roLessEqual: Result := roGreaterEqual;
    roGreater: Result := roLess;
    roGreaterEqual: Result := roLessEqual;
  else
    Result := Op;
  end;
end;

{ The contents of "( ... )" as a media feature, or nil. }
function ParseFeature(Contents: TCssTokenCursor): TCssMediaCondition;
var
  Token: PCssToken;
  Name: string;
  Op, SecondOp: TCssRangeOperator;
  Value, SecondValue: TCssValue;
  Saved: Integer;
begin
  Result := nil;
  Contents.SkipWhitespace;
  Token := Contents.Peek;
  Saved := Contents.Position;
  if Token^.Kind = tkIdent then
  begin
    Name := AsciiLowercase(Token^.Text);
    Inc(Contents.Position);
    if Contents.AtEndIgnoringWhitespace then
    begin
      Result := TCssMediaCondition.Create;
      Result.Kind := mcFeature;
      Result.Name := Name;
      Exit;
    end;
    Contents.SkipWhitespace;
    if Contents.PeekKind = tkColon then
    begin
      Inc(Contents.Position);
      Value := ParseFeatureValue(Contents);
      if (Value = nil) or not Contents.AtEndIgnoringWhitespace then
      begin
        ReleaseValue(Value);
        Exit;
      end;
      Result := TCssMediaCondition.Create;
      Result.Kind := mcFeature;
      Result.Value2 := Value;
      if (Copy(Name, 1, 4) = 'min-') or (Copy(Name, 1, 4) = 'max-') then
      begin
        Result.WrittenPrefix := Copy(Name, 1, 4);
        if Result.WrittenPrefix = 'min-' then
          Result.Op2 := roGreaterEqual
        else
          Result.Op2 := roLessEqual;
        Result.Name := Copy(Name, 5, Length(Name));
      end
      else
      begin
        Result.Name := Name;
        Result.Op2 := roEqual;
      end;
      Exit;
    end;
    { name op value }
    if ParseOperator(Contents, Op) then
    begin
      Value := ParseFeatureValue(Contents);
      if (Value <> nil) and Contents.AtEndIgnoringWhitespace then
      begin
        Result := TCssMediaCondition.Create;
        Result.Kind := mcFeature;
        Result.Name := Name;
        Result.Op2 := Op;
        Result.Value2 := Value;
        Exit;
      end;
      ReleaseValue(Value);
    end;
    Exit;
  end;
  { value op name [op value] }
  Contents.Position := Saved;
  Value := ParseFeatureValue(Contents);
  if Value = nil then
    Exit;
  if not ParseOperator(Contents, Op) then
  begin
    Value.Release;
    Exit;
  end;
  Contents.SkipWhitespace;
  Token := Contents.Peek;
  if Token^.Kind <> tkIdent then
  begin
    Value.Release;
    Exit;
  end;
  Name := AsciiLowercase(Token^.Text);
  Inc(Contents.Position);
  Result := TCssMediaCondition.Create;
  Result.Kind := mcFeature;
  Result.Name := Name;
  Result.Op1 := Op;
  Result.Value1 := Value;
  if Contents.AtEndIgnoringWhitespace then
    Exit;
  SecondValue := nil;
  if ParseOperator(Contents, SecondOp) then
    SecondValue := ParseFeatureValue(Contents);
  { Both comparisons must point the same way, and neither be '='. }
  if (SecondValue = nil) or not Contents.AtEndIgnoringWhitespace or (Op = roEqual) or (SecondOp = roEqual) or
    ((Op in [roLess, roLessEqual]) <> (SecondOp in [roLess, roLessEqual])) then
  begin
    ReleaseValue(SecondValue);
    FreeAndNil(Result);
    Exit;
  end;
  Result.Op2 := SecondOp;
  Result.Value2 := SecondValue;
end;

function ParseInParens(var Cursor: TCssTokenCursor): TCssMediaCondition;
var
  Token: PCssToken;
  Contents: TCssTokenCursor;
  Inner: TCssMediaCondition;
  Start: Integer;
begin
  Result := nil;
  Cursor.SkipWhitespace;
  Start := Cursor.Position;
  Token := Cursor.Peek;
  if Token^.Kind = tkOpenParen then
  begin
    Cursor.Next;
    Contents := Cursor.Contents(Token);
    { A nested condition, or a feature. }
    Inner := ParseMediaCondition(Contents, True);
    if (Inner <> nil) and Contents.AtEndIgnoringWhitespace then
      Exit(Inner);
    Inner.Free;
    Contents := Cursor.Contents(Token);
    Result := ParseFeature(Contents);
    if Result <> nil then
      Exit;
  end
  else if Token^.Kind = tkFunction then
    Cursor.Next
  else
    Exit;
  { General enclosed: valid, but unknown. }
  Result := TCssMediaCondition.Create;
  Result.Kind := mcUnknown;
  Result.Text := SerializeTokens(TCssTokenCursor.CreateRange(Cursor.Tokens, Start, Cursor.Position));
end;

function ParseMediaCondition(var Cursor: TCssTokenCursor; AllowOr: Boolean): TCssMediaCondition;
var
  First, Next: TCssMediaCondition;
  Keyword, Joiner: TCssKeyword;
  Saved: Integer;
begin
  Result := nil;
  Keyword := PeekKeyword(Cursor);
  if Keyword = kwNot then
  begin
    Cursor.NextNonWhitespace;
    First := ParseInParens(Cursor);
    if First = nil then
      Exit;
    Result := TCssMediaCondition.Create;
    Result.Kind := mcNot;
    SetLength(Result.Children, 1);
    Result.Children[0] := First;
    Exit;
  end;
  First := ParseInParens(Cursor);
  if First = nil then
    Exit;
  Joiner := kwInvalid;
  repeat
    Saved := Cursor.Position;
    Keyword := PeekKeyword(Cursor);
    if not ((Keyword = kwAnd) or ((Keyword = kwOr) and AllowOr)) or
      ((Joiner <> kwInvalid) and (Keyword <> Joiner)) then
    begin
      Cursor.Position := Saved;
      Break;
    end;
    Cursor.NextNonWhitespace;
    Next := ParseInParens(Cursor);
    if Next = nil then
    begin
      First.Free;
      Result.Free;
      Exit(nil);
    end;
    if Result = nil then
    begin
      Result := TCssMediaCondition.Create;
      if Keyword = kwAnd then
        Result.Kind := mcAnd
      else
        Result.Kind := mcOr;
      SetLength(Result.Children, 1);
      Result.Children[0] := First;
      Joiner := Keyword;
    end;
    SetLength(Result.Children, Length(Result.Children) + 1);
    Result.Children[High(Result.Children)] := Next;
  until False;
  if Result = nil then
    Result := First;
end;

function ParseQuery(Cursor: TCssTokenCursor; out Query: TCssMediaQuery): Boolean;
var
  Token: PCssToken;
  Keyword: TCssKeyword;
  Saved: Integer;
begin
  Query := Default(TCssMediaQuery);
  Result := False;
  Cursor.SkipWhitespace;
  if Cursor.AtEnd then
    Exit;
  Saved := Cursor.Position;
  { A condition alone. }
  Query.Condition := ParseMediaCondition(Cursor, True);
  if (Query.Condition <> nil) and Cursor.AtEndIgnoringWhitespace then
    Exit(True);
  FreeAndNil(Query.Condition);
  Cursor.Position := Saved;
  Keyword := PeekKeyword(Cursor);
  if (Keyword = kwNot) or (Keyword = kwOnly) then
  begin
    Query.Negated := Keyword = kwNot;
    Query.Only := Keyword = kwOnly;
    Cursor.NextNonWhitespace;
  end;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if Token^.Kind <> tkIdent then
    Exit;
  Keyword := KeywordOfAtom(FindAtom(AsciiLowercase(Token^.Text)));
  if KeywordIn(Keyword, [kwOnly, kwNot, kwAnd, kwOr, kwLayer]) then
    Exit;
  Query.MediaType := AsciiLowercase(Token^.Text);
  Inc(Cursor.Position);
  if Cursor.AtEndIgnoringWhitespace then
    Exit(True);
  if PeekKeyword(Cursor) <> kwAnd then
    Exit;
  Cursor.NextNonWhitespace;
  Query.Condition := ParseMediaCondition(Cursor, False);
  Result := (Query.Condition <> nil) and Cursor.AtEndIgnoringWhitespace;
  if not Result then
    FreeAndNil(Query.Condition);
end;

function ParseMediaQueryList(Cursor: TCssTokenCursor): TCssMediaQueryList;
var
  Pieces: TCssTokenCursorArray;
  Index: Integer;
  Query: TCssMediaQuery;
begin
  Result := TCssMediaQueryList.Create;
  if Cursor.AtEndIgnoringWhitespace then
    Exit;
  Pieces := SplitAtCommas(Cursor);
  SetLength(Result.Queries, Length(Pieces));
  for Index := 0 to High(Pieces) do
  begin
    if not ParseQuery(Pieces[Index], Query) then
    begin
      Query := Default(TCssMediaQuery);
      Query.Invalid := True;
    end;
    Result.Queries[Index] := Query;
  end;
end;

function ParseMediaQueryText(const Text: string): TCssMediaQueryList;
begin
  Result := ParseMediaQueryList(TCssTokenCursor.Create(TokenizeCss(Text)));
end;

{ ---- evaluation ---- }

function DefaultMediaEnvironment: TCssMediaEnvironment;
begin
  Result := Default(TCssMediaEnvironment);
  Result.MediaType := kwScreen;
  Result.Width := 1280;
  Result.Height := 800;
  Result.DeviceWidth := 1280;
  Result.DeviceHeight := 800;
  Result.Resolution := 1;
  Result.ColorBits := 8;
  Result.Contrast := kwNoPreference;
  Result.Hover := kwHover;
  Result.AnyHover := kwHover;
  Result.Pointer := kwFine;
  Result.AnyPointer := kwFine;
  Result.Scripting := kwEnabled;
  Result.DisplayMode := kwBrowser;
  Result.ColorGamut := kwSrgb;
  Result.DynamicRange := kwStandard;
  Result.Update := kwFast;
  Result.FontSize := 16;
end;

{ A value as a number in the feature's canonical unit; False if it does not fit. }
function NumericValue(Value: TCssValue; const Environment: TCssMediaEnvironment; out Number: Double;
  out Category: TCssUnitCategory): Boolean;
begin
  Result := True;
  Category := ucNumber;
  case Value.Kind of
    vkNumber, vkInteger: Number := Value.Number;
    vkDimension:
      begin
        Category := UnitCategory(Value.UnitValue);
        case Value.UnitValue of
          cuEm, cuRem: Number := Value.Number * Environment.FontSize;
          cuEx, cuRex, cuCh, cuRch: Number := Value.Number * Environment.FontSize / 2;
          cuVw, cuSvw, cuLvw, cuDvw, cuVi: Number := Value.Number * Environment.Width / 100;
          cuVh, cuSvh, cuLvh, cuDvh, cuVb: Number := Value.Number * Environment.Height / 100;
          cuVmin: Number := Value.Number * Min(Environment.Width, Environment.Height) / 100;
          cuVmax: Number := Value.Number * Max(Environment.Width, Environment.Height) / 100;
        else
          if CanonicalFactor(Value.UnitValue) = 0 then
            Exit(False);
          Number := Value.Number * CanonicalFactor(Value.UnitValue);
        end;
      end;
    vkCalc:
      begin
        Number := EvaluateCalc(Value.Calc, nil, nil);
        Category := ucLength;
      end;
    vkList:
      if (Value.Separator = lsSlash) and (Value.Count = 2) and (Value.Items[1].Number <> 0) then
        Number := Value.Items[0].Number / Value.Items[1].Number
      else
        Exit(False);
  else
    Result := False;
  end;
end;

function Compare(Left: Double; Op: TCssRangeOperator; Right: Double): Boolean;
const
  Epsilon = 1E-9;
begin
  case Op of
    roEqual: Result := Abs(Left - Right) < Epsilon;
    roLess: Result := Left < Right - Epsilon;
    roLessEqual: Result := Left <= Right + Epsilon;
    roGreater: Result := Left > Right + Epsilon;
    roGreaterEqual: Result := Left >= Right - Epsilon;
  else
    Result := False;
  end;
end;

function TriState(Value: Boolean): TCssTriState;
begin
  if Value then
    Result := tsTrue
  else
    Result := tsFalse;
end;

function EvaluateRange(Condition: TCssMediaCondition; Actual: Double; Expected: TCssUnitCategory;
  const Environment: TCssMediaEnvironment): TCssTriState;
var
  Number: Double;
  Category: TCssUnitCategory;
  Matches: Boolean;
begin
  Matches := True;
  if Condition.Op1 <> roNone then
  begin
    if not NumericValue(Condition.Value1, Environment, Number, Category) or
      ((Category <> Expected) and not ((Category = ucNumber) and (Number = 0))) then
      Exit(tsUnknown);
    { "Value1 Op1 name": compare name against Value1 with the operator flipped. }
    Matches := Compare(Actual, Flip(Condition.Op1), Number);
  end;
  if Condition.Op2 <> roNone then
  begin
    if not NumericValue(Condition.Value2, Environment, Number, Category) or
      ((Category <> Expected) and not ((Category = ucNumber) and (Number = 0))) then
      Exit(tsUnknown);
    Matches := Matches and Compare(Actual, Condition.Op2, Number);
  end;
  if (Condition.Op1 = roNone) and (Condition.Op2 = roNone) then
    Matches := Actual <> 0;
  Result := TriState(Matches);
end;

function EvaluateKeyword(Condition: TCssMediaCondition; Actual: TCssKeyword; FalseInBooleanContext: TCssKeyword): TCssTriState;
var
  Wanted: TCssKeyword;
begin
  if (Condition.Op1 = roNone) and (Condition.Op2 = roNone) then
    Exit(TriState(Actual <> FalseInBooleanContext));
  if (Condition.Op1 <> roNone) or (Condition.Op2 <> roEqual) or (Condition.WrittenPrefix <> '') or
    (Condition.Value2.Kind <> vkCustomIdent) then
    Exit(tsUnknown);
  Wanted := KeywordOfAtom(FindAtom(Condition.Value2.Text));
  Result := TriState(Wanted = Actual);
end;

function BooleanKeyword(Value: Boolean; WhenTrue, WhenFalse: TCssKeyword): TCssKeyword;
begin
  if Value then
    Result := WhenTrue
  else
    Result := WhenFalse;
end;

function EvaluateFeature(Condition: TCssMediaCondition; const Environment: TCssMediaEnvironment): TCssTriState;
var
  Name: string;
begin
  Name := Condition.Name;
  if Name = 'width' then Result := EvaluateRange(Condition, Environment.Width, ucLength, Environment)
  else if Name = 'height' then Result := EvaluateRange(Condition, Environment.Height, ucLength, Environment)
  else if Name = 'device-width' then Result := EvaluateRange(Condition, Environment.DeviceWidth, ucLength, Environment)
  else if Name = 'device-height' then
    Result := EvaluateRange(Condition, Environment.DeviceHeight, ucLength, Environment)
  else if Name = 'aspect-ratio' then
    Result := EvaluateRange(Condition, Environment.Width / Max(1, Environment.Height), ucNumber, Environment)
  else if Name = 'device-aspect-ratio' then
    Result := EvaluateRange(Condition, Environment.DeviceWidth / Max(1, Environment.DeviceHeight), ucNumber,
      Environment)
  else if Name = 'resolution' then
  begin
    if (Condition.Op2 = roEqual) and (Condition.Value2.Kind = vkCustomIdent) then
      Result := TriState(Condition.Value2.Text = 'infinite')
    else
      Result := EvaluateRange(Condition, Environment.Resolution, ucResolution, Environment);
  end
  else if Name = '-webkit-device-pixel-ratio' then
    Result := EvaluateRange(Condition, Environment.Resolution, ucNumber, Environment)
  else if Name = 'orientation' then
    Result := EvaluateKeyword(Condition, BooleanKeyword(Environment.Height >= Environment.Width, kwPortrait,
      kwLandscape), kwInvalid)
  else if Name = 'color' then Result := EvaluateRange(Condition, Environment.ColorBits, ucNumber, Environment)
  else if Name = 'color-index' then Result := EvaluateRange(Condition, 0, ucNumber, Environment)
  else if Name = 'monochrome' then Result := EvaluateRange(Condition, Environment.MonochromeBits, ucNumber, Environment)
  else if Name = 'grid' then Result := EvaluateRange(Condition, 0, ucNumber, Environment)
  else if Name = 'prefers-color-scheme' then
    Result := EvaluateKeyword(Condition, BooleanKeyword(Environment.DarkColorScheme, kwDark, kwLight), kwInvalid)
  else if Name = 'prefers-reduced-motion' then
    Result := EvaluateKeyword(Condition, BooleanKeyword(Environment.ReducedMotion, kwReduce, kwNoPreference),
      kwNoPreference)
  else if Name = 'prefers-reduced-transparency' then
    Result := EvaluateKeyword(Condition, BooleanKeyword(Environment.ReducedTransparency, kwReduce,
      kwNoPreference), kwNoPreference)
  else if Name = 'prefers-reduced-data' then
    Result := EvaluateKeyword(Condition, BooleanKeyword(Environment.ReducedData, kwReduce, kwNoPreference),
      kwNoPreference)
  else if Name = 'prefers-contrast' then Result := EvaluateKeyword(Condition, Environment.Contrast, kwNoPreference)
  else if Name = 'forced-colors' then
    Result := EvaluateKeyword(Condition, BooleanKeyword(Environment.ForcedColors, kwActive, kwNone), kwNone)
  else if Name = 'inverted-colors' then
    Result := EvaluateKeyword(Condition, BooleanKeyword(Environment.InvertedColors, kwInverted, kwNone), kwNone)
  else if Name = 'hover' then Result := EvaluateKeyword(Condition, Environment.Hover, kwNone)
  else if Name = 'any-hover' then Result := EvaluateKeyword(Condition, Environment.AnyHover, kwNone)
  else if Name = 'pointer' then Result := EvaluateKeyword(Condition, Environment.Pointer, kwNone)
  else if Name = 'any-pointer' then Result := EvaluateKeyword(Condition, Environment.AnyPointer, kwNone)
  else if Name = 'scripting' then Result := EvaluateKeyword(Condition, Environment.Scripting, kwNone)
  else if Name = 'display-mode' then Result := EvaluateKeyword(Condition, Environment.DisplayMode, kwInvalid)
  else if Name = 'color-gamut' then
  begin
    { A device covering a larger gamut matches the smaller ones too. }
    Result := EvaluateKeyword(Condition, Environment.ColorGamut, kwInvalid);
    if (Result = tsFalse) and (Condition.Value2 <> nil) then
      if (Condition.Value2.Text = 'srgb') or ((Condition.Value2.Text = 'p3') and
        (Environment.ColorGamut = kwRec2020)) then
        Result := tsTrue;
  end
  else if Name = 'dynamic-range' then
  begin
    Result := EvaluateKeyword(Condition, Environment.DynamicRange, kwInvalid);
    if (Result = tsFalse) and (Condition.Value2 <> nil) and (Condition.Value2.Text = 'standard') then
      Result := tsTrue;
  end
  else if Name = 'update' then Result := EvaluateKeyword(Condition, Environment.Update, kwNone)
  else if Name = 'scan' then Result := EvaluateKeyword(Condition, kwProgressive, kwInvalid)
  else if (Name = 'overflow-block') or (Name = 'overflow-inline') then
    Result := EvaluateKeyword(Condition, BooleanKeyword(Environment.MediaType = kwPrint, kwPaged, kwScroll), kwNone)
  else
    Result := tsUnknown;
end;

function EvaluateMediaCondition(Condition: TCssMediaCondition; const Environment: TCssMediaEnvironment): TCssTriState;
var
  Index: Integer;
  Child: TCssTriState;
begin
  case Condition.Kind of
    mcFeature: Result := EvaluateFeature(Condition, Environment);
    mcNot:
      case EvaluateMediaCondition(Condition.Children[0], Environment) of
        tsTrue: Result := tsFalse;
        tsFalse: Result := tsTrue;
      else
        Result := tsUnknown;
      end;
    mcAnd:
      begin
        Result := tsTrue;
        for Index := 0 to High(Condition.Children) do
        begin
          Child := EvaluateMediaCondition(Condition.Children[Index], Environment);
          if Child = tsFalse then
            Exit(tsFalse);
          if Child = tsUnknown then
            Result := tsUnknown;
        end;
      end;
    mcOr:
      begin
        Result := tsFalse;
        for Index := 0 to High(Condition.Children) do
        begin
          Child := EvaluateMediaCondition(Condition.Children[Index], Environment);
          if Child = tsTrue then
            Exit(tsTrue);
          if Child = tsUnknown then
            Result := tsUnknown;
        end;
      end;
  else
    Result := tsUnknown;
  end;
end;

function MediaTypeMatches(const MediaType: string; const Environment: TCssMediaEnvironment): Boolean;
begin
  if (MediaType = '') or (MediaType = 'all') then
    Result := True
  else
    Result := MediaType = KeywordName(Environment.MediaType);
end;

function TCssMediaQueryList.Matches(const Environment: TCssMediaEnvironment): Boolean;
var
  Index: Integer;
  Query: ^TCssMediaQuery;
  Matched: Boolean;
begin
  if Length(Queries) = 0 then
    Exit(True);
  for Index := 0 to High(Queries) do
  begin
    Query := @Queries[Index];
    if Query^.Invalid then
      Continue;
    Matched := MediaTypeMatches(Query^.MediaType, Environment);
    if Matched and (Query^.Condition <> nil) then
      Matched := EvaluateMediaCondition(Query^.Condition, Environment) = tsTrue;
    if Query^.Negated then
      Matched := not Matched;
    if Matched then
      Exit(True);
  end;
  Result := False;
end;

end.

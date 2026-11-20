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
  Computing values (CSS Cascading 5 section 4.4 and each property's
  "computed value" line): from the cascaded values of an element and
  its parent's computed style to its own computed style.

  Relative lengths become px (em against the element's font size, or
  the parent's for font-size itself; rem against the root's; viewport
  units against the viewport; container units fall back to the small
  viewport), percentages stay, currentcolor stays except in 'color',
  var() is substituted, 'inherit', 'initial' and 'unset' are applied,
  display is blockified for floats, absolutely positioned boxes and
  the root, and a border or outline whose style is none or hidden has
  a width of 0.

  A group nothing was declared for is not rebuilt: the element takes
  the parent's struct (inherited groups) or the initial one. Rebuilt
  structs are interned in the struct cache.
}
unit Css.StyleCompute;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.Units, Css.Colors, Css.Values, Css.PropertyIds, Css.ComputedValues, Css.StyleStructs,
  Css.ComputedStyle, Css.Cascade, Css.CustomProperties, Css.RuleIndex, Css.MediaQueries;

type
  TCssInitialStructs = array[TCssStructGroup] of PCssStyleStruct;

  TCssComputeContext = record
    Parent: TCssComputedStyle;
    IsRoot: Boolean;
    ParentFontSize, FontSize, RootFontSize: Double;
    LineHeight, RootLineHeight: Double;
    ViewportWidth, ViewportHeight: Double;
    { Device pixels per CSS pixel. }
    Resolution: Double;
    Color, ParentColor: TCssColor;
    DarkScheme: Boolean;
    EnvironmentDark: Boolean;
    { em and percentages relative to the parent's font size. }
    ForFontSize: Boolean;
  end;

  TCssStyleComputer = class
  private
    FCache: TCssStructCache;
    FInitial: TCssInitialStructs;
    FIndex: TCssRuleIndex;
    FEnvironment: TCssMediaEnvironment;
    procedure BuildInitialStructs;
  public
    constructor Create(Cache: TCssStructCache; Index: TCssRuleIndex; const Environment: TCssMediaEnvironment);
    destructor Destroy; override;
    { A new style (one reference for the caller). RootStyle is the root
      element's style (nil when styling the root). }
    function Compute(var Cascaded: TCssCascadedValues; Parent, RootStyle: TCssComputedStyle;
      IsRoot: Boolean): TCssComputedStyle;
    { The style of an element nothing applies to, under Parent. }
    function InitialStyle: TCssComputedStyle;
    { The style of an anonymous box (or a box no rule styles) under
      Parent: Parent's inherited groups and custom properties, the
      initial values of the rest. }
    function AnonymousStyle(Parent: TCssComputedStyle): TCssComputedStyle;
    property InitialStructs: TCssInitialStructs read FInitial;
  end;

{ px of a length leaf in a context (the calc() resolver). }
function ResolveLengthLeaf(Value: Double; UnitValue: TCssUnit; Data: Pointer): Double;

implementation

uses
  SysUtils, Math, Css.Keywords, Css.Calc, Css.Tokens, Css.Properties, Css.PropertyTable,
  Css.InitialValues, Css.Grammar, Css.Shorthands, Css.ColorParser, Css.Declarations, Css.ValueParser;

type
  PComputeContext = ^TCssComputeContext;

const
  FontSizeKeywords: array[0..7] of Double = (9, 10, 13, 16, 18, 24, 32, 48);
  InitialFontSize = 16;

function ResolveLengthLeaf(Value: Double; UnitValue: TCssUnit; Data: Pointer): Double;
var
  Context: PComputeContext;
  Em: Double;
  Inline, Block: Double;
begin
  Context := PComputeContext(Data);
  if Context^.ForFontSize then
    Em := Context^.ParentFontSize
  else
    Em := Context^.FontSize;
  Inline := Context^.ViewportWidth;
  Block := Context^.ViewportHeight;
  case UnitValue of
    cuEm: Result := Value * Em;
    cuRem: Result := Value * Context^.RootFontSize;
    cuEx, cuCh: Result := Value * Em * 0.5;
    cuRex, cuRch: Result := Value * Context^.RootFontSize * 0.5;
    cuCap: Result := Value * Em * 0.7;
    cuRcap: Result := Value * Context^.RootFontSize * 0.7;
    cuIc: Result := Value * Em;
    cuRic: Result := Value * Context^.RootFontSize;
    cuLh: Result := Value * Context^.LineHeight;
    cuRlh: Result := Value * Context^.RootLineHeight;
    cuVw, cuSvw, cuLvw, cuDvw, cuCqw: Result := Value * Context^.ViewportWidth / 100;
    cuVh, cuSvh, cuLvh, cuDvh, cuCqh: Result := Value * Context^.ViewportHeight / 100;
    cuVi, cuSvi, cuLvi, cuDvi, cuCqi: Result := Value * Inline / 100;
    cuVb, cuSvb, cuLvb, cuDvb, cuCqb: Result := Value * Block / 100;
    cuVmin, cuSvmin, cuLvmin, cuDvmin, cuCqmin:
      Result := Value * Min(Context^.ViewportWidth, Context^.ViewportHeight) / 100;
    cuVmax, cuSvmax, cuLvmax, cuDvmax, cuCqmax:
      Result := Value * Max(Context^.ViewportWidth, Context^.ViewportHeight) / 100;
    cuPercent:
      if Context^.ForFontSize then
        Result := Value * Context^.ParentFontSize / 100
      else
        Result := Value;
  else
    Result := Value * CanonicalFactor(UnitValue);
  end;
end;

{ ---- making values absolute ---- }

function NeedsAbsolutizing(Value: TCssValue): Boolean;
var
  Index: Integer;
begin
  case Value.Kind of
    vkDimension: Result := (UnitCategory(Value.UnitValue) = ucLength) and (Value.UnitValue <> cuPx);
    vkCalc: Result := True;
    vkList, vkFunction:
      begin
        for Index := 0 to Value.Count - 1 do
          if NeedsAbsolutizing(Value.Items[Index]) then
            Exit(True);
        Result := False;
      end;
  else
    Result := False;
  end;
end;

{ Value with its lengths in px (a new reference). }
function AbsolutizeValue(Value: TCssValue; var Context: TCssComputeContext): TCssValue;
var
  Index: Integer;
  Node: TCssCalcNode;
begin
  if not NeedsAbsolutizing(Value) then
    Exit(Value.AddRef);
  case Value.Kind of
    vkDimension:
      Result := NewDimension(ResolveLengthLeaf(Value.Number, Value.UnitValue, @Context), cuPx);
    vkCalc:
      begin
        Node := AbsolutizeCalc(Value.Calc, @ResolveLengthLeaf, @Context);
        if Node.IsLeaf and (Node.UnitValue = cuPx) then
        begin
          Result := NewDimension(Node.Value, cuPx);
          Node.Free;
        end
        else if Node.IsLeaf and (Node.UnitValue = cuNone) then
        begin
          Result := NewNumber(Node.Value);
          Node.Free;
        end
        else
          Result := NewCalc(Node);
      end;
  else
    begin
      if Value.Kind = vkList then
        Result := NewList(Value.Separator)
      else
        Result := NewFunction(Value.Text);
      Result.Text := Value.Text;
      Result.Separator := Value.Separator;
      for Index := 0 to Value.Count - 1 do
        Result.Add(AbsolutizeValue(Value.Items[Index], Context));
    end;
  end;
end;

{ ---- computing one value ---- }

function ComputeGeneric(Value: TCssValue; var Context: TCssComputeContext): TCssComputedValue;
var
  Absolute: TCssValue;
  Pixels, Percent: Double;
begin
  case Value.Kind of
    vkKeyword:
      if Value.Keyword = kwCurrentcolor then
        Result := ComputedCurrentColor
      else
        Result := ComputedKeyword(Value.Keyword);
    vkNumber: Result := ComputedNumber(Value.Number);
    vkInteger: Result := ComputedInteger(Round(Value.Number));
    vkPercentage: Result := ComputedPercentage(Value.Number);
    vkDimension:
      if UnitCategory(Value.UnitValue) = ucLength then
        Result := ComputedLength(ResolveLengthLeaf(Value.Number, Value.UnitValue, @Context))
      else
        Result := ComputedTree(Value.AddRef);
    vkColor: Result := ComputedColor(Value.Color);
    vkCalc:
      begin
        Absolute := AbsolutizeValue(Value, Context);
        if Absolute.Kind = vkDimension then
          Result := ComputedLength(Absolute.Number)
        else if Absolute.Kind = vkNumber then
          Result := ComputedNumber(Absolute.Number)
        else if CalcAsLengthPercentage(Absolute.Calc, Pixels, Percent) then
          Result := ComputedLengthPercentage(Pixels, Percent)
        else
        begin
          Result := ComputedCalc(Absolute);
          Exit;
        end;
        Absolute.Release;
      end;
  else
    Result := ComputedTree(AbsolutizeValue(Value, Context));
  end;
end;

function ComputeLineWidth(Value: TCssValue; var Context: TCssComputeContext): TCssComputedValue;
begin
  if Value.Kind = vkKeyword then
    case Value.Keyword of
      kwThin: Exit(ComputedLength(1));
      kwMedium: Exit(ComputedLength(3));
      kwThick: Exit(ComputedLength(5));
    end;
  Result := ComputeGeneric(Value, Context);
  if Result.Kind = cvLength then
    Result.Number := Max(0, Result.Number);
end;

{ Border widths snap to whole device pixels, at least one when not 0. }
procedure SnapBorderWidth(var Value: TCssComputedValue; Resolution: Double);
var
  DevicePixels: Double;
begin
  if (Value.Kind <> cvLength) or (Value.Number <= 0) then
    Exit;
  if Resolution <= 0 then
    Resolution := 1;
  DevicePixels := Value.Number * Resolution;
  if DevicePixels < 1 then
    DevicePixels := 1
  else
    DevicePixels := Floor(DevicePixels + 1E-6);
  Value.Number := DevicePixels / Resolution;
end;

function ComputeColorValue(Value: TCssValue; var Context: TCssComputeContext): TCssComputedValue;
var
  Color: TCssColor;
begin
  if Value.IsKeyword(kwCurrentcolor) then
    Exit(ComputedCurrentColor);
  if Value.Kind = vkKeyword then
  begin
    if IsSystemColorKeyword(Value.Keyword) then
      Exit(ComputedColor(SystemColor(Value.Keyword, Context.DarkScheme)));
    Exit(ComputedKeyword(Value.Keyword));
  end;
  if ResolveColor(Value, Context.Color, Context.DarkScheme, Color) then
    Result := ComputedColor(Color)
  else
    Result := ComputeGeneric(Value, Context);
end;

function ComputeFontWeight(Value: TCssValue; var Context: TCssComputeContext): TCssComputedValue;
var
  ParentWeight: Double;
begin
  ParentWeight := 400;
  if Context.Parent <> nil then
    ParentWeight := Context.Parent.Value(cpFontWeight)^.Number;
  if Value.Kind = vkKeyword then
    case Value.Keyword of
      kwNormal: Exit(ComputedNumber(400));
      kwBold: Exit(ComputedNumber(700));
      kwBolder:
        begin
          if ParentWeight < 350 then Exit(ComputedNumber(400));
          if ParentWeight < 550 then Exit(ComputedNumber(700));
          if ParentWeight < 900 then Exit(ComputedNumber(900));
          Exit(ComputedNumber(ParentWeight));
        end;
      kwLighter:
        begin
          if ParentWeight < 100 then Exit(ComputedNumber(ParentWeight));
          if ParentWeight < 550 then Exit(ComputedNumber(100));
          if ParentWeight < 750 then Exit(ComputedNumber(400));
          Exit(ComputedNumber(700));
        end;
    end;
  Result := ComputeGeneric(Value, Context);
  if Result.Kind = cvNumber then
    Result.Number := Max(1, Min(1000, Result.Number));
end;

function ComputeLineHeight(Value: TCssValue; var Context: TCssComputeContext): TCssComputedValue;
begin
  case Value.Kind of
    vkKeyword: Result := ComputedKeyword(Value.Keyword);
    vkNumber, vkInteger: Result := ComputedNumber(Value.Number);
    vkPercentage: Result := ComputedLength(Value.Number * Context.FontSize / 100);
  else
    begin
      Result := ComputeGeneric(Value, Context);
      if Result.Kind = cvPercentage then
        Result := ComputedLength(Result.Percent * Context.FontSize / 100)
      else if Result.Kind = cvLengthPercentage then
        Result := ComputedLength(Result.Number + Result.Percent * Context.FontSize / 100);
    end;
  end;
end;

function ComputeOpacity(Value: TCssValue; var Context: TCssComputeContext): TCssComputedValue;
var
  Number: Double;
begin
  case Value.Kind of
    vkNumber, vkInteger: Number := Value.Number;
    vkPercentage: Number := Value.Number / 100;
    vkCalc: Number := EvaluateCalc(Value.Calc, @ResolveLengthLeaf, @Context);
  else
    Number := 1;
  end;
  Result := ComputedNumber(Max(0, Min(1, Number)));
end;

function ComputeNumberValue(Value: TCssValue; var Context: TCssComputeContext; Integral: Boolean): TCssComputedValue;
var
  Number: Double;
begin
  if Value.Kind = vkCalc then
  begin
    Number := EvaluateCalc(Value.Calc, @ResolveLengthLeaf, @Context);
    if IsNan(Number) or IsInfinite(Number) then
      Number := 0;
    if Integral then
      Result := ComputedInteger(Round(Number))
    else
      Result := ComputedNumber(Number);
    Exit;
  end;
  Result := ComputeGeneric(Value, Context);
end;

function ComputeValue(Id: TCssPropertyId; Value: TCssValue; var Context: TCssComputeContext): TCssComputedValue;
begin
  case PropertyTable[Id].Compute of
    cmpColor, cmpForegroundColor: Result := ComputeColorValue(Value, Context);
    cmpLineWidth: Result := ComputeLineWidth(Value, Context);
    cmpFontWeight: Result := ComputeFontWeight(Value, Context);
    cmpLineHeight: Result := ComputeLineHeight(Value, Context);
    cmpOpacity: Result := ComputeOpacity(Value, Context);
    cmpNumber: Result := ComputeNumberValue(Value, Context, False);
    cmpInteger: Result := ComputeNumberValue(Value, Context, True);
  else
    Result := ComputeGeneric(Value, Context);
  end;
end;

{ ---- font size and color, which others depend on ---- }

function ComputeFontSize(Value: TCssValue; var Context: TCssComputeContext): Double;
var
  Saved: Boolean;
begin
  Result := Context.ParentFontSize;
  if Value = nil then
    Exit;
  Saved := Context.ForFontSize;
  Context.ForFontSize := True;
  try
    case Value.Kind of
      vkKeyword:
        case Value.Keyword of
          kwXxSmall..kwXxxLarge: Result := FontSizeKeywords[Ord(Value.Keyword) - Ord(kwXxSmall)];
          kwLarger: Result := Context.ParentFontSize * 1.2;
          kwSmaller: Result := Context.ParentFontSize / 1.2;
          kwInitial: Result := InitialFontSize;
        end;
      vkDimension: Result := ResolveLengthLeaf(Value.Number, Value.UnitValue, @Context);
      vkPercentage: Result := Context.ParentFontSize * Value.Number / 100;
      vkCalc: Result := EvaluateCalc(Value.Calc, @ResolveLengthLeaf, @Context);
    end;
  finally
    Context.ForFontSize := Saved;
  end;
  if IsNan(Result) or (Result < 0) then
    Result := 0;
end;

{ Whether a color-scheme value lets the dark scheme be used. }
function SchemeIsDark(Value: TCssValue): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if Value = nil then
    Exit;
  if Value.IsKeyword(kwDark) then
    Exit(True);
  if Value.Kind = vkList then
    for Index := 0 to Value.Count - 1 do
      if Value.Items[Index].IsKeyword(kwDark) then
        Exit(True);
end;

function IsCssWide(Value: TCssValue; Keyword: TCssKeyword): Boolean; inline;
begin
  Result := (Value <> nil) and (Value.Kind = vkKeyword) and (Value.Keyword = Keyword);
end;

{ ---- custom properties ---- }

type
  TCustomState = (csDone, csPending, csResolving, csInCycle);

  TCustomResolution = record
    Cascaded: ^TCssCascadedValues;
    Properties: TCssCustomProperties;
    States: array of TCustomState;
    Stack: array of Integer;
    Depth: Integer;
  end;
  PCustomResolution = ^TCustomResolution;

function ResolveCustom(var Resolution: TCustomResolution; Index: Integer): Boolean; forward;

function CustomLookup(Name: TCssAtom; out Tokens: TCssTokenArray; Data: Pointer): Boolean;
var
  Resolution: PCustomResolution;
  Index, StackIndex: Integer;
begin
  Resolution := PCustomResolution(Data);
  for Index := 0 to Resolution^.Cascaded^.CustomCount - 1 do
    if Resolution^.Cascaded^.CustomNames[Index] = Name then
    begin
      case Resolution^.States[Index] of
        csResolving, csInCycle:
          begin
            { A cycle: everything on the stack from Index up is in it. }
            for StackIndex := Resolution^.Depth - 1 downto 0 do
            begin
              Resolution^.States[Resolution^.Stack[StackIndex]] := csInCycle;
              if Resolution^.Stack[StackIndex] = Index then
                Break;
            end;
            Tokens := nil;
            Exit(False);
          end;
        csPending: ResolveCustom(Resolution^, Index);
      end;
      Break;
    end;
  Result := Resolution^.Properties.Find(Name, Tokens);
end;

function ResolveCustom(var Resolution: TCustomResolution; Index: Integer): Boolean;
var
  Output: TCssTokenArray;
  Name: TCssAtom;
  Valid: Boolean;
begin
  Name := Resolution.Cascaded^.CustomNames[Index];
  Resolution.States[Index] := csResolving;
  if Resolution.Depth >= Length(Resolution.Stack) then
    SetLength(Resolution.Stack, Resolution.Depth * 2 + 8);
  Resolution.Stack[Resolution.Depth] := Index;
  Inc(Resolution.Depth);
  Valid := SubstituteVariables(Resolution.Cascaded^.CustomValues[Index].Tokens, @CustomLookup, @Resolution, Output);
  Dec(Resolution.Depth);
  if Resolution.States[Index] = csInCycle then
    Valid := False;
  if Valid then
    Resolution.Properties.Put(Name, Output)
  else
    Resolution.Properties.Remove(Name);
  if Resolution.States[Index] <> csInCycle then
    Resolution.States[Index] := csDone;
  Result := Valid;
end;

function ComputeCustomProperties(var Cascaded: TCssCascadedValues; Parent: TCssComputedStyle;
  Index: TCssRuleIndex; IsRoot: Boolean): TCssCustomProperties;
var
  Resolution: TCustomResolution;
  CustomIndex, Item: Integer;
  ParentSet: TCssCustomProperties;
  Value: TCssValue;
  Name: TCssAtom;
  Registered: TCssRegisteredProperty;
  Tokens: TCssTokenArray;
  NeedsCopy: Boolean;
begin
  ParentSet := nil;
  if Parent <> nil then
    ParentSet := Parent.Custom;
  NeedsCopy := Cascaded.CustomCount > 0;
  if Index.HasRegisteredProperties then
    NeedsCopy := True;
  if not NeedsCopy then
    Exit(ParentSet.AddRef);
  Result := ParentSet.Clone;
  { Registered properties: non-inherited ones start from their initial
    value on every element; every initial value is there at the root. }
  if Index.HasRegisteredProperties then
    for Item := Result.Count - 1 downto 0 do
      if Index.FindRegisteredProperty(Result.NameAt(Item), Registered) and not Registered.Inherits then
        Result.Remove(Result.NameAt(Item));
  for CustomIndex := 0 to Cascaded.CustomCount - 1 do
  begin
    Name := Cascaded.CustomNames[CustomIndex];
    Value := Cascaded.CustomValues[CustomIndex];
    if Value = nil then
      Continue;
    if Value.Kind = vkKeyword then
    begin
      case Value.Keyword of
        kwInitial: Result.Remove(Name);
        kwInherit:
          if ParentSet.Find(Name, Tokens) then
            Result.Put(Name, Tokens)
          else
            Result.Remove(Name);
      end;
      { unset: inherited (already copied from the parent). }
    end
    else if not HasVariableReference(Value.Tokens) then
      Result.Put(Name, Value.Tokens);
  end;
  Resolution.Cascaded := @Cascaded;
  Resolution.Properties := Result;
  SetLength(Resolution.States, Cascaded.CustomCount);
  Resolution.Stack := nil;
  Resolution.Depth := 0;
  for CustomIndex := 0 to Cascaded.CustomCount - 1 do
  begin
    Value := Cascaded.CustomValues[CustomIndex];
    if (Value <> nil) and (Value.Kind = vkUnparsed) and HasVariableReference(Value.Tokens) then
      Resolution.States[CustomIndex] := csPending
    else
      Resolution.States[CustomIndex] := csDone;
  end;
  for CustomIndex := 0 to Cascaded.CustomCount - 1 do
    if Resolution.States[CustomIndex] = csPending then
      ResolveCustom(Resolution, CustomIndex);
  { Registered initial values where nothing gave a value. }
  for Item := 0 to Index.RegisteredCount - 1 do
  begin
    Registered := Index.RegisteredAt(Item);
    if Registered.Rule.HasInitialValue and not Result.Find(Registered.Name, Tokens) then
      Result.Put(Registered.Name, Registered.Rule.InitialValue);
  end;
end;

{ ---- the computer ---- }

constructor TCssStyleComputer.Create(Cache: TCssStructCache; Index: TCssRuleIndex;
  const Environment: TCssMediaEnvironment);
begin
  inherited Create;
  FCache := Cache;
  FIndex := Index;
  FEnvironment := Environment;
  BuildInitialStructs;
end;

destructor TCssStyleComputer.Destroy;
var
  Group: TCssStructGroup;
begin
  for Group := Low(TCssStructGroup) to High(TCssStructGroup) do
    ReleaseStruct(FInitial[Group]);
  inherited Destroy;
end;

procedure ApplyFixups(Struct: PCssStyleStruct; var Context: TCssComputeContext);
const
  WidthOf: array[0..3] of TCssPropertyId = (cpBorderTopWidth, cpBorderRightWidth, cpBorderBottomWidth,
    cpBorderLeftWidth);
  StyleOf: array[0..3] of TCssPropertyId = (cpBorderTopStyle, cpBorderRightStyle, cpBorderBottomStyle,
    cpBorderLeftStyle);
var
  Side: Integer;
  Style: TCssKeyword;
  Width, Display, Position, FloatValue: PCssComputedValue;
  Blockify: Boolean;
  NewDisplay: TCssKeyword;
begin
  case Struct^.Group of
    pgBorder:
      for Side := 0 to 3 do
      begin
        Width := StructValue(Struct, PropertySlot(WidthOf[Side]));
        Style := KeywordOfComputed(StructValue(Struct, PropertySlot(StyleOf[Side]))^);
        if (Style = kwNone) or (Style = kwHidden) then
          Width^ := ComputedLength(0)
        else
          SnapBorderWidth(Width^, Context.Resolution);
      end;
    pgOutline:
      begin
        Width := StructValue(Struct, PropertySlot(cpOutlineWidth));
        if KeywordOfComputed(StructValue(Struct, PropertySlot(cpOutlineStyle))^) = kwNone then
          Width^ := ComputedLength(0)
        else
          SnapBorderWidth(Width^, Context.Resolution);
      end;
    pgColumn:
      begin
        Width := StructValue(Struct, PropertySlot(cpColumnRuleWidth));
        Style := KeywordOfComputed(StructValue(Struct, PropertySlot(cpColumnRuleStyle))^);
        if (Style = kwNone) or (Style = kwHidden) then
          Width^ := ComputedLength(0)
        else
          SnapBorderWidth(Width^, Context.Resolution);
      end;
    pgBox:
      begin
        Display := StructValue(Struct, PropertySlot(cpDisplay));
        Position := StructValue(Struct, PropertySlot(cpPosition));
        FloatValue := StructValue(Struct, PropertySlot(cpFloat));
        if KeywordIn(KeywordOfComputed(Position^), [kwAbsolute, kwFixed]) then
          FloatValue^ := ComputedKeyword(kwNone);
        Blockify := Context.IsRoot or not IsComputedKeyword(FloatValue^, kwNone) or
          KeywordIn(KeywordOfComputed(Position^), [kwAbsolute, kwFixed]);
        if Blockify then
        begin
          NewDisplay := KeywordOfComputed(Display^);
          case NewDisplay of
            kwInline, kwInlineBlock, kwRunIn, kwTableRowGroup, kwTableHeaderGroup, kwTableFooterGroup,
            kwTableRow, kwTableCell, kwTableColumnGroup, kwTableColumn, kwTableCaption, kwRubyBase,
            kwRubyText, kwRubyBaseContainer, kwRubyTextContainer, kwRuby, kwMath:
              NewDisplay := kwBlock;
            kwInlineTable: NewDisplay := kwTable;
            kwInlineFlex: NewDisplay := kwFlex;
            kwInlineGrid: NewDisplay := kwGrid;
            kwWebkitInlineBox: NewDisplay := kwWebkitBox;
            kwContents:
              if Context.IsRoot then
                NewDisplay := kwBlock;
            kwInvalid:
              { A two value display: inline list-item and the like. }
              if (Display^.Kind = cvValue) and (Display^.Data <> nil) and (Display^.Data.Count >= 1) and
                Display^.Data.Items[0].IsKeyword(kwInline) then
              begin
                ReleaseComputed(Display^);
                Display^ := ComputedKeyword(kwListItem);
              end;
          end;
          if (NewDisplay <> kwInvalid) and (Display^.Kind = cvKeyword) then
            Display^ := ComputedKeyword(NewDisplay);
        end;
      end;
  end;
end;

procedure TCssStyleComputer.BuildInitialStructs;
var
  Group: TCssStructGroup;
  Slot: Integer;
  Context: TCssComputeContext;
  Id: TCssPropertyId;
  Struct: PCssStyleStruct;
begin
  Context := Default(TCssComputeContext);
  Context.ParentFontSize := InitialFontSize;
  Context.FontSize := InitialFontSize;
  Context.RootFontSize := InitialFontSize;
  Context.LineHeight := InitialFontSize * 1.2;
  Context.RootLineHeight := Context.LineHeight;
  Context.ViewportWidth := FEnvironment.Width;
  Context.ViewportHeight := FEnvironment.Height;
  Context.Resolution := FEnvironment.Resolution;
  Context.EnvironmentDark := FEnvironment.DarkColorScheme;
  Context.Color := SystemColor(kwCanvastext, False);
  Context.ParentColor := Context.Color;
  for Group := Low(TCssStructGroup) to High(TCssStructGroup) do
  begin
    Struct := NewStruct(Group);
    for Slot := 0 to Struct^.Count - 1 do
    begin
      Id := PropertyAtSlot(Group, Slot);
      if Id = cpFontSize then
        Struct^.Values[Slot] := ComputedLength(InitialFontSize)
      else
        Struct^.Values[Slot] := ComputeValue(Id, InitialValue(Id), Context);
    end;
    ApplyFixups(Struct, Context);
    FCache.Intern(Struct);
    FInitial[Group] := Struct;
  end;
end;

function TCssStyleComputer.InitialStyle: TCssComputedStyle;
var
  Group: TCssStructGroup;
begin
  Result := TCssComputedStyle.Create;
  for Group := Low(TCssStructGroup) to High(TCssStructGroup) do
  begin
    Result.Structs[Group] := FInitial[Group];
    AddRefStruct(FInitial[Group]);
  end;
end;

function TCssStyleComputer.AnonymousStyle(Parent: TCssComputedStyle): TCssComputedStyle;
var
  Group: TCssStructGroup;
begin
  if Parent = nil then
    Exit(InitialStyle);
  Result := TCssComputedStyle.Create;
  for Group := Low(TCssStructGroup) to High(TCssStructGroup) do
  begin
    if Group in InheritedGroups then
      Result.Structs[Group] := Parent.Structs[Group]
    else
      Result.Structs[Group] := FInitial[Group];
    AddRefStruct(Result.Structs[Group]);
  end;
  Result.Custom := Parent.Custom.AddRef;
end;

type
  { Values made while substituting var(), released after computing. }
  TResolvedValues = record
    Values: array of TCssValue;
    Count: Integer;
  end;

procedure Keep(var Resolved: TResolvedValues; Value: TCssValue);
begin
  if Resolved.Count >= Length(Resolved.Values) then
    SetLength(Resolved.Values, Resolved.Count * 2 + 8);
  Resolved.Values[Resolved.Count] := Value;
  Inc(Resolved.Count);
end;

function PropertiesLookup(Name: TCssAtom; out Tokens: TCssTokenArray; Data: Pointer): Boolean;
begin
  Result := TCssCustomProperties(Data).Find(Name, Tokens);
end;

{ The value of an unparsed (var()) declaration for physical Id, or nil
  when it is invalid at computed-value time. }
function ResolveUnparsed(Id: TCssPropertyId; Value: TCssValue; Properties: TCssCustomProperties;
  const Cascaded: TCssCascadedValues; var Resolved: TResolvedValues): TCssValue;
var
  Tokens: TCssTokenArray;
  Cursor: TCssTokenCursor;
  Keyword: TCssKeyword;
  Shorthand: TCssPropertyId;
  Longhands: TCssPropertyIdArray;
  Values: TCssValueArray;
  Index: Integer;
begin
  Result := nil;
  if not SubstituteVariables(Value.Tokens, @PropertiesLookup, Properties, Tokens) then
    Exit;
  Cursor := TrimRange(TCssTokenCursor.Create(Tokens));
  if Cursor.AtEnd then
    Exit;
  Keyword := PeekKeyword(Cursor);
  if CssWideKeyword(Keyword) then
  begin
    Cursor.NextNonWhitespace;
    if Cursor.AtEndIgnoringWhitespace then
    begin
      Result := NewKeyword(Keyword);
      Keep(Resolved, Result);
      Exit;
    end;
    Cursor := TrimRange(TCssTokenCursor.Create(Tokens));
  end;
  if Value.Shorthand >= 0 then
  begin
    Shorthand := TCssPropertyId(Value.Shorthand);
    if not ExpandShorthand(Shorthand, Cursor, Values) then
      Exit;
    Longhands := ShorthandLonghands(Shorthand);
    for Index := 0 to High(Longhands) do
    begin
      if (Result = nil) and ((Longhands[Index] = Id) or
        (IsLogical(Longhands[Index]) and (PhysicalProperty(Longhands[Index], Cascaded.WritingMode,
        Cascaded.RightToLeft) = Id))) then
      begin
        Result := Values[Index];
        Keep(Resolved, Result);
      end
      else
        Values[Index].Release;
    end;
    Exit;
  end;
  Result := ParseLonghandValue(Id, Cursor);
  if Result <> nil then
    Keep(Resolved, Result);
end;

function TCssStyleComputer.Compute(var Cascaded: TCssCascadedValues; Parent, RootStyle: TCssComputedStyle;
  IsRoot: Boolean): TCssComputedStyle;
var
  Context: TCssComputeContext;
  Resolved: TResolvedValues;
  Id: TCssPropertyId;
  Group: TCssStructGroup;
  Slot, Index: Integer;
  Value: TCssValue;
  Struct, InheritedStruct: PCssStyleStruct;
  AnySet, IsInherited: Boolean;
  FontSizeValue, ColorValue: TCssComputedValue;
  ColorScheme: TCssValue;
  LineHeightValue: TCssComputedValue;
begin
  Result := TCssComputedStyle.Create;
  Resolved.Values := nil;
  Resolved.Count := 0;
  try
    Result.Custom := ComputeCustomProperties(Cascaded, Parent, FIndex, IsRoot);
    { var() first, so that every value below is parsed. }
    for Id := Succ(cpInvalid) to High(TCssPhysicalId) do
    begin
      Value := Cascaded.Values[Id];
      if (Value <> nil) and (Value.Kind = vkUnparsed) then
      begin
        Value := ResolveUnparsed(Id, Value, Result.Custom, Cascaded, Resolved);
        { Invalid at computed-value time: as unset. }
        if Value = nil then
        begin
          Value := NewKeyword(kwUnset);
          Keep(Resolved, Value);
        end;
        Cascaded.Values[Id] := Value;
      end;
    end;

    Context := Default(TCssComputeContext);
    Context.Parent := Parent;
    Context.IsRoot := IsRoot;
    Context.ViewportWidth := FEnvironment.Width;
    Context.ViewportHeight := FEnvironment.Height;
    Context.Resolution := FEnvironment.Resolution;
    Context.EnvironmentDark := FEnvironment.DarkColorScheme;
    if Parent <> nil then
    begin
      Context.ParentFontSize := Parent.FontSize;
      Context.ParentColor := Parent.Color;
    end
    else
    begin
      Context.ParentFontSize := InitialFontSize;
      Context.ParentColor := SystemColor(kwCanvastext, Context.EnvironmentDark);
    end;
    if RootStyle <> nil then
      Context.RootFontSize := RootStyle.FontSize
    else
      Context.RootFontSize := InitialFontSize;
    Context.RootLineHeight := Context.RootFontSize * 1.2;

    { color-scheme decides which system colors are used. }
    ColorScheme := Cascaded.Values[cpColorScheme];
    if (ColorScheme = nil) or IsCssWide(ColorScheme, kwInherit) or IsCssWide(ColorScheme, kwUnset) then
    begin
      ColorScheme := nil;
      if Parent <> nil then
        ColorScheme := Parent.Value(cpColorScheme)^.Data;
    end;
    Context.DarkScheme := Context.EnvironmentDark and SchemeIsDark(ColorScheme);

    { Font size: em and percentages against the parent's. }
    Value := Cascaded.Values[cpFontSize];
    if (Value = nil) or IsCssWide(Value, kwInherit) or IsCssWide(Value, kwUnset) then
      Context.FontSize := Context.ParentFontSize
    else if IsCssWide(Value, kwInitial) then
      Context.FontSize := InitialFontSize
    else
      Context.FontSize := ComputeFontSize(Value, Context);
    if IsRoot then
      Context.RootFontSize := Context.FontSize;
    FontSizeValue := ComputedLength(Context.FontSize);

    { The color: currentcolor in it is the parent's color. }
    Value := Cascaded.Values[cpColor];
    Context.Color := Context.ParentColor;
    if (Value <> nil) and not (IsCssWide(Value, kwInherit) or IsCssWide(Value, kwUnset)) then
    begin
      if IsCssWide(Value, kwInitial) then
        Context.Color := SystemColor(kwCanvastext, Context.DarkScheme)
      else if Value.IsKeyword(kwCurrentcolor) then
        Context.Color := Context.ParentColor
      else
      begin
        Context.Color := Context.ParentColor;
        ColorValue := ComputeColorValue(Value, Context);
        Context.Color := ComputedToColor(ColorValue, Context.ParentColor);
      end;
    end;
    ColorValue := ComputedColor(Context.Color);

    { The line height, for lh units. }
    Context.LineHeight := Context.FontSize * 1.2;

    for Group := Low(TCssStructGroup) to High(TCssStructGroup) do
    begin
      IsInherited := Group in InheritedGroups;
      if (Parent <> nil) and IsInherited then
        InheritedStruct := Parent.Structs[Group]
      else
        InheritedStruct := FInitial[Group];
      AnySet := (Group = pgBox) and IsRoot;
      for Slot := 0 to GroupSize(Group) - 1 do
        if Cascaded.Values[PropertyAtSlot(Group, Slot)] <> nil then
        begin
          AnySet := True;
          Break;
        end;
      if (Parent = nil) and ((Group = pgFont) or (Group = pgInheritedText)) then
        AnySet := True;
      if not AnySet then
      begin
        Result.Structs[Group] := InheritedStruct;
        AddRefStruct(InheritedStruct);
        Continue;
      end;
      Struct := NewStruct(Group);
      for Slot := 0 to Struct^.Count - 1 do
      begin
        Id := PropertyAtSlot(Group, Slot);
        if Id = cpFontSize then
        begin
          Struct^.Values[Slot] := FontSizeValue;
          Continue;
        end;
        if Id = cpColor then
        begin
          Struct^.Values[Slot] := ColorValue;
          Continue;
        end;
        Value := Cascaded.Values[Id];
        if (Value = nil) or IsCssWide(Value, kwUnset) then
        begin
          if IsInherited and (Parent <> nil) then
            Struct^.Values[Slot] := Parent.Structs[Group]^.Values[Slot]
          else
            Struct^.Values[Slot] := FInitial[Group]^.Values[Slot];
          AddRefComputed(Struct^.Values[Slot]);
        end
        else if IsCssWide(Value, kwInherit) then
        begin
          if Parent <> nil then
            Struct^.Values[Slot] := Parent.Structs[Group]^.Values[Slot]
          else
            Struct^.Values[Slot] := FInitial[Group]^.Values[Slot];
          AddRefComputed(Struct^.Values[Slot]);
        end
        else if IsCssWide(Value, kwInitial) then
        begin
          Struct^.Values[Slot] := FInitial[Group]^.Values[Slot];
          AddRefComputed(Struct^.Values[Slot]);
        end
        else
          Struct^.Values[Slot] := ComputeValue(Id, Value, Context);
        if Id = cpLineHeight then
        begin
          LineHeightValue := Struct^.Values[Slot];
          if LineHeightValue.Kind = cvLength then
            Context.LineHeight := LineHeightValue.Number
          else if LineHeightValue.Kind = cvNumber then
            Context.LineHeight := LineHeightValue.Number * Context.FontSize;
        end;
      end;
      ApplyFixups(Struct, Context);
      FCache.Intern(Struct);
      Result.Structs[Group] := Struct;
    end;
  finally
    for Index := 0 to Resolved.Count - 1 do
      Resolved.Values[Index].Release;
  end;
end;

end.

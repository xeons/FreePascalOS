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
  The keyframe effects of Web Animations (Element.animate, KeyframeEffect)
  in styling. Script (platform/77-animations.js) owns the timing model:
  each frame it works out every effect's iteration progress and hands
  it here with the effect's keyframes (computed offsets, per keyframe
  easing, the declarations); the styler's Animate applies the effects
  in effect order over the CSS animations (Web.Style.Animations), each
  property interpolated between the keyframes around the progress with
  Css.Interpolation, the underlying value standing in for a missing 0%
  or 100% keyframe (implicit keyframes). Composite modes other than
  replace are applied as replace.

  The effects live with their target element (TElement.AnimationEffects,
  owned), so an element keeps them while it is out of the document.
}
unit Web.Style.ScriptAnimations;

{$mode objfpc}
{$H+}
{$modeswitch nestedprocvars}

interface

uses
  SysUtils, Web.Dom, Css.Values, Css.Colors, Css.PropertyIds, Css.ComputedValues, Css.ComputedStyle,
  Css.Declarations, Css.StyleEngine, Css.Interpolation;

type
  TScriptKeyframe = record
    Offset: Double;
    { The easing to the next keyframe (nil: linear); owned. }
    Easing: TCssValue;
    Block: TCssDeclarationBlock;
  end;

  TScriptEffect = class
  public
    Handle: Integer;
    Keyframes: array of TScriptKeyframe;
    InEffect: Boolean;
    Progress: Double;
    KeyframeStyles: array of TCssComputedStyle;
    KeyframesParent: TCssComputedStyle;
    destructor Destroy; override;
    procedure ClearStyles;
    procedure ClearKeyframes;
  end;

  TScriptAnimationEffects = class
  public
    Effects: array of TScriptEffect;
    destructor Destroy; override;
    function Find(Handle: Integer): TScriptEffect;
    function Ensure(Handle: Integer): TScriptEffect;
    procedure Remove(Handle: Integer);
    function AnyInEffect: Boolean;
  end;

  TOverrideProc = procedure(Id: TCssPropertyId; const Value: TCssComputedValue) is nested;

{ Element's effects (made on first use; owned by the element). }
function EffectsOf(Element: TElement): TScriptAnimationEffects;
function ExistingEffectsOf(Element: TElement): TScriptAnimationEffects; inline;
{ An effect's keyframes: Offsets ascending in [0, 1], Easings (CSS
  easing text, '' linear) and Declarations (CSS declaration text). }
procedure SetEffectKeyframes(Element: TElement; Handle: Integer; const Offsets: array of Double;
  const Easings, Declarations: array of string);
{ The effect's progress now (InEffect False: it shows nothing); the
  element's style is due again. }
procedure SetEffectProgress(Element: TElement; Handle: Integer; InEffect: Boolean; Progress: Double);
procedure RemoveEffect(Element: TElement; Handle: Integer);
{ Whether Element has effects that show something. }
function HasEffectsInEffect(Element: TElement): Boolean;
{ Applies Element's effects over Base (keyframes computed under
  ParentStyle), each property's value given to SetOverride. }
procedure ApplyEffects(Element: TElement; Engine: TCssStyleEngine; Base, ParentStyle: TCssComputedStyle;
  SetOverride: TOverrideProc);
{ Easing text applied to a progress (cached parses), for the timing
  model's effect easing. }
function EaseProgress(const EasingText: string; Progress: Double): Double;

implementation

uses
  Css.Parser, Css.Easing, Web.Style.NodeData;

var
  EasingTexts: array of string;
  EasingValues: array of TCssValue;

{ An easing function's value from its text, a new reference ('' is
  linear; nil when invalid). EasedProgress takes nil as ease, so linear
  is always an explicit value. }
function ParseEasing(const Text: string): TCssValue;
var
  Block: TCssDeclarationBlock;
  Declaration: PCssDeclaration;
  Index: Integer;
begin
  Result := nil;
  if Text = '' then
  begin
    Result := ParseEasing('linear');
    Exit;
  end;
  for Index := 0 to High(EasingTexts) do
    if EasingTexts[Index] = Text then
    begin
      Result := EasingValues[Index];
      if Result <> nil then
        Result.AddRef;
      Exit;
    end;
  Block := ParseStyleAttribute('animation-timing-function: ' + Text);
  try
    Declaration := Block.Find(cpAnimationTimingFunction);
    if (Declaration <> nil) and (Declaration^.Value <> nil) then
    begin
      Result := Declaration^.Value;
      { The property's value is a comma list of easings. }
      if (Result.Kind = vkList) and (Result.Separator = lsComma) and (Result.Count > 0) then
        Result := Result.Items[0];
      Result.AddRef;
    end;
  finally
    Block.Free;
  end;
  if Length(EasingTexts) < 64 then
  begin
    SetLength(EasingTexts, Length(EasingTexts) + 1);
    SetLength(EasingValues, Length(EasingValues) + 1);
    EasingTexts[High(EasingTexts)] := Text;
    EasingValues[High(EasingValues)] := Result;
    if Result <> nil then
      Result.AddRef;
  end;
end;

function EaseProgress(const EasingText: string; Progress: Double): Double;
var
  Easing: TCssValue;
begin
  if (EasingText = '') or (EasingText = 'linear') then
    Exit(Progress);
  Easing := ParseEasing(EasingText);
  try
    Result := EasedProgress(Easing, Progress);
  finally
    Easing.Release;
  end;
end;

{ TScriptEffect }

procedure TScriptEffect.ClearStyles;
var
  Index: Integer;
begin
  for Index := 0 to High(KeyframeStyles) do
    KeyframeStyles[Index].Release;
  KeyframeStyles := nil;
  KeyframesParent.Release;
  KeyframesParent := nil;
end;

procedure TScriptEffect.ClearKeyframes;
var
  Index: Integer;
begin
  ClearStyles;
  for Index := 0 to High(Keyframes) do
  begin
    Keyframes[Index].Easing.Release;
    Keyframes[Index].Block.Free;
  end;
  Keyframes := nil;
end;

destructor TScriptEffect.Destroy;
begin
  ClearKeyframes;
  inherited Destroy;
end;

{ TScriptAnimationEffects }

destructor TScriptAnimationEffects.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Effects) do
    Effects[Index].Free;
  inherited Destroy;
end;

function TScriptAnimationEffects.Find(Handle: Integer): TScriptEffect;
var
  Index: Integer;
begin
  for Index := 0 to High(Effects) do
    if Effects[Index].Handle = Handle then
      Exit(Effects[Index]);
  Result := nil;
end;

function TScriptAnimationEffects.Ensure(Handle: Integer): TScriptEffect;
begin
  Result := Find(Handle);
  if Result <> nil then
    Exit;
  Result := TScriptEffect.Create;
  Result.Handle := Handle;
  SetLength(Effects, Length(Effects) + 1);
  Effects[High(Effects)] := Result;
end;

procedure TScriptAnimationEffects.Remove(Handle: Integer);
var
  Index, Position: Integer;
begin
  for Index := 0 to High(Effects) do
    if Effects[Index].Handle = Handle then
    begin
      Effects[Index].Free;
      for Position := Index + 1 to High(Effects) do
        Effects[Position - 1] := Effects[Position];
      SetLength(Effects, Length(Effects) - 1);
      Exit;
    end;
end;

function TScriptAnimationEffects.AnyInEffect: Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Effects) do
    if Effects[Index].InEffect and (Length(Effects[Index].Keyframes) > 0) then
      Exit(True);
  Result := False;
end;

function ExistingEffectsOf(Element: TElement): TScriptAnimationEffects;
begin
  Result := TScriptAnimationEffects(Element.AnimationEffects);
end;

function EffectsOf(Element: TElement): TScriptAnimationEffects;
begin
  Result := ExistingEffectsOf(Element);
  if Result = nil then
  begin
    Result := TScriptAnimationEffects.Create;
    Element.AnimationEffects := Result;
  end;
end;

procedure StyleDue(Element: TElement);
begin
  if Element.IsConnected then
    MarkAnimationDirty(Element);
end;

procedure SetEffectKeyframes(Element: TElement; Handle: Integer; const Offsets: array of Double;
  const Easings, Declarations: array of string);
var
  Effect: TScriptEffect;
  Index: Integer;
begin
  Effect := EffectsOf(Element).Ensure(Handle);
  Effect.ClearKeyframes;
  SetLength(Effect.Keyframes, Length(Offsets));
  for Index := 0 to High(Offsets) do
  begin
    Effect.Keyframes[Index].Offset := Offsets[Index];
    Effect.Keyframes[Index].Easing := ParseEasing(Easings[Index]);
    Effect.Keyframes[Index].Block := ParseStyleAttribute(Declarations[Index]);
  end;
  StyleDue(Element);
end;

procedure SetEffectProgress(Element: TElement; Handle: Integer; InEffect: Boolean; Progress: Double);
var
  Effect: TScriptEffect;
begin
  Effect := EffectsOf(Element).Ensure(Handle);
  if (Effect.InEffect = InEffect) and (not InEffect or (Effect.Progress = Progress)) then
    Exit;
  Effect.InEffect := InEffect;
  Effect.Progress := Progress;
  StyleDue(Element);
end;

procedure RemoveEffect(Element: TElement; Handle: Integer);
var
  Effects: TScriptAnimationEffects;
begin
  Effects := ExistingEffectsOf(Element);
  if Effects = nil then
    Exit;
  Effects.Remove(Handle);
  StyleDue(Element);
end;

function HasEffectsInEffect(Element: TElement): Boolean;
var
  Effects: TScriptAnimationEffects;
begin
  Effects := ExistingEffectsOf(Element);
  Result := (Effects <> nil) and Effects.AnyInEffect;
end;

{ The keyframes' computed styles under ParentStyle. }
procedure PrepareStyles(Effect: TScriptEffect; Engine: TCssStyleEngine; ParentStyle: TCssComputedStyle);
var
  Index: Integer;
begin
  if (Effect.KeyframesParent = ParentStyle) and (Length(Effect.KeyframeStyles) = Length(Effect.Keyframes)) then
    Exit;
  Effect.ClearStyles;
  if ParentStyle <> nil then
    Effect.KeyframesParent := ParentStyle.AddRef;
  SetLength(Effect.KeyframeStyles, Length(Effect.Keyframes));
  for Index := 0 to High(Effect.Keyframes) do
    Effect.KeyframeStyles[Index] := Engine.ComputeBlockStyle(Effect.Keyframes[Index].Block, ParentStyle);
end;

{ The value of Id at Progress: between the keyframes declaring it around
  the progress (before the first and after the last: the underlying
  value at 0 and 1). }
function EffectValue(Effect: TScriptEffect; Id: TCssPropertyId; Base: TCssComputedStyle; Progress: Double;
  out Value: TCssComputedValue): Boolean;
var
  Offsets: array of Double;
  Values: array of PCssComputedValue;
  Colors: array of TCssColor;
  Easings: array of TCssValue;
  Count, Index, Before, After: Integer;
  Span, Local: Double;

  procedure AddPoint(Offset: Double; Source: TCssComputedStyle; Easing: TCssValue);
  begin
    SetLength(Offsets, Count + 1);
    SetLength(Values, Count + 1);
    SetLength(Colors, Count + 1);
    SetLength(Easings, Count + 1);
    Offsets[Count] := Offset;
    Values[Count] := Source.Value(Id);
    Colors[Count] := Source.Color;
    Easings[Count] := Easing;
    Inc(Count);
  end;

begin
  Result := False;
  Count := 0;
  Offsets := nil;
  Values := nil;
  Colors := nil;
  Easings := nil;
  for Index := 0 to High(Effect.Keyframes) do
    if Effect.Keyframes[Index].Block.Find(Id) <> nil then
    begin
      if (Count = 0) and (Effect.Keyframes[Index].Offset > 0) then
        AddPoint(0, Base, nil);
      AddPoint(Effect.Keyframes[Index].Offset, Effect.KeyframeStyles[Index], Effect.Keyframes[Index].Easing);
    end;
  if Count = 0 then
    Exit;
  if Offsets[Count - 1] < 1 then
    AddPoint(1, Base, nil);
  Before := 0;
  for Index := 0 to Count - 1 do
    if Offsets[Index] <= Progress then
      Before := Index;
  if Progress < Offsets[0] then
    Before := 0;
  After := Before;
  if (Before < Count - 1) and (Offsets[Before] <= Progress) then
    After := Before + 1
  else if (Progress < Offsets[0]) and (Count > 1) then
    After := 1;
  if After = Before then
  begin
    Value := Values[Before]^;
    AddRefComputed(Value);
    Exit(True);
  end;
  Span := Offsets[After] - Offsets[Before];
  if Span <= 0 then
    Local := 1
  else
    Local := (Progress - Offsets[Before]) / Span;
  if Easings[Before] = nil then
    Local := EaseProgress('', Local)
  else
    Local := EasedProgress(Easings[Before], Local);
  if not InterpolateComputed(Id, Values[Before]^, Values[After]^, Colors[Before], Colors[After], Local, Value) then
  begin
    if Local < 0.5 then
      Value := Values[Before]^
    else
      Value := Values[After]^;
    AddRefComputed(Value);
  end;
  Result := True;
end;

procedure ApplyEffects(Element: TElement; Engine: TCssStyleEngine; Base, ParentStyle: TCssComputedStyle;
  SetOverride: TOverrideProc);
var
  Effects: TScriptAnimationEffects;
  Effect: TScriptEffect;
  Index, Frame, Slot: Integer;
  Block: TCssDeclarationBlock;
  Id: TCssPropertyId;
  Value: TCssComputedValue;
begin
  Effects := ExistingEffectsOf(Element);
  if Effects = nil then
    Exit;
  for Index := 0 to High(Effects.Effects) do
  begin
    Effect := Effects.Effects[Index];
    if not Effect.InEffect or (Length(Effect.Keyframes) = 0) then
      Continue;
    PrepareStyles(Effect, Engine, ParentStyle);
    for Frame := 0 to High(Effect.Keyframes) do
    begin
      Block := Effect.Keyframes[Frame].Block;
      for Slot := 0 to Block.Count - 1 do
      begin
        Id := Block.Item(Slot)^.Id;
        if not IsAnimatable(Id) then
          Continue;
        if EffectValue(Effect, Id, Base, Effect.Progress, Value) then
          SetOverride(Id, Value);
      end;
    end;
  end;
end;

procedure ReleaseEasings;
var
  Index: Integer;
begin
  for Index := 0 to High(EasingValues) do
    EasingValues[Index].Release;
  EasingValues := nil;
  EasingTexts := nil;
end;

finalization
  ReleaseEasings;
end.

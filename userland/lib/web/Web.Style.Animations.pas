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
  CSS Animations 1 and CSS Transitions 1 in styling.

  The styler hands every element's cascaded style to Animate, which
  keeps the element's running animations (from animation-name and the
  other animation properties, with the @keyframes rule of each name)
  and transitions (started when a transitioned property's cascaded
  value changes, from the value shown then) and gives the style to
  show: the cascaded style with the animated values over it (libcss's
  Css.Interpolation interpolates and builds it). The cascaded style is
  kept in the node's data as BaseStyle meanwhile.

  Time comes from a clock the owner can replace (tests set fixed times).
  Each frame the owner calls MarkDue: elements with running effects get
  ndAnimationDirty, and the styler makes their style again from the
  kept base without cascading. Events (animationstart, animationend,
  animationiteration, transitionrun, transitionstart, transitionend,
  transitioncancel) are collected for the owner to dispatch outside
  styling (TakeEvents).
}
unit Web.Style.Animations;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils, Web.Dom, Css.Values, Css.Colors, Css.PropertyIds, Css.ComputedValues, Css.ComputedStyle,
  Css.Stylesheets, Css.StyleEngine;

type
  TAnimationClock = function: Double of object;

  TAnimationEventKind = (aeAnimationStart, aeAnimationEnd, aeAnimationIteration, aeAnimationCancel,
    aeTransitionRun, aeTransitionStart, aeTransitionEnd, aeTransitionCancel);

  TPendingAnimationEvent = record
    Element: TElement;
    Kind: TAnimationEventKind;
    { The animation's or the property's name. }
    Name: string;
    { Seconds. }
    ElapsedTime: Double;
  end;
  TPendingAnimationEventArray = array of TPendingAnimationEvent;

  TStyleAnimations = class
  private
    FEngine: TCssStyleEngine;
    FClock: TAnimationClock;
    FActive: array of TElement;
    FEvents: TPendingAnimationEventArray;
    FEventCount: Integer;
    function SystemClock: Double;
    procedure AddActive(Element: TElement);
    procedure RemoveActive(Element: TElement);
    procedure QueueEvent(Element: TElement; Kind: TAnimationEventKind; const Name: string; Elapsed: Double);
  public
    constructor Create(Engine: TCssStyleEngine);
    { The style Element shows (a new reference): NewBase, its cascaded
      style, with its animations and transitions over it. OldBase and
      OldShown: what it had (nil for a new element); ParentStyle: what
      keyframes inherit from. Keeps or drops the node's BaseStyle and
      animation state. }
    function Animate(Element: TElement; OldBase, OldShown, NewBase, ParentStyle: TCssComputedStyle): TCssComputedStyle;
    { Something runs (a frame is wanted). }
    function Running: Boolean;
    { Time moved: elements with running effects are marked for their
      style to be made again. }
    procedure MarkDue;
    { The element left the document (its data is freed by the styler). }
    procedure ElementRemoved(Element: TElement);
    { The events collected since the last call, for the owner to fire. }
    function TakeEvents: TPendingAnimationEventArray;
    { Milliseconds; replaceable (tests). }
    property Clock: TAnimationClock read FClock write FClock;
  end;

{ The DOM event type of an animation event. }
function AnimationEventType(Kind: TAnimationEventKind): string;

implementation

uses
  Math, Css.Keywords, Css.Units, Css.Easing, Css.Interpolation, Css.Properties, Css.Shorthands, Css.Declarations,
  Web.Style.NodeData;

type
  TRunningAnimation = record
    Name: string;
    StartTime: Double;
    { Milliseconds. }
    Duration, Delay: Double;
    Iterations: Double;
    Direction: TCssKeyword;
    FillMode: TCssKeyword;
    Easing: TCssValue;
    Paused: Boolean;
    PausedAt: Double;
    Started, Ended: Boolean;
    LastIteration: Int64;
    { The keyframes' computed styles (one per keyframe rule), made from
      the base style they were computed under. }
    Keyframes: TCssKeyframesRule;
    KeyframeStyles: array of TCssComputedStyle;
    KeyframesParent: TCssComputedStyle;
  end;

  TRunningTransition = record
    Id: TCssPropertyId;
    StartValue, EndValue: TCssComputedValue;
    StartColor, EndColor: TCssColor;
    StartTime, Duration, Delay: Double;
    Easing: TCssValue;
    Started: Boolean;
  end;

  TElementAnimations = class
  public
    Animations: array of TRunningAnimation;
    Transitions: array of TRunningTransition;
    destructor Destroy; override;
    procedure ClearAnimation(Index: Integer);
    procedure RemoveAnimation(Index: Integer);
    procedure RemoveTransition(Index: Integer);
    function HasEffects: Boolean;
  end;

function AnimationEventType(Kind: TAnimationEventKind): string;
begin
  case Kind of
    aeAnimationStart: Result := 'animationstart';
    aeAnimationEnd: Result := 'animationend';
    aeAnimationIteration: Result := 'animationiteration';
    aeAnimationCancel: Result := 'animationcancel';
    aeTransitionRun: Result := 'transitionrun';
    aeTransitionStart: Result := 'transitionstart';
    aeTransitionEnd: Result := 'transitionend';
  else
    Result := 'transitioncancel';
  end;
end;

{ ---- TElementAnimations ---- }

procedure TElementAnimations.ClearAnimation(Index: Integer);
var
  Frame: Integer;
begin
  for Frame := 0 to High(Animations[Index].KeyframeStyles) do
    Animations[Index].KeyframeStyles[Frame].Release;
  Animations[Index].KeyframeStyles := nil;
  Animations[Index].KeyframesParent.Release;
  Animations[Index].KeyframesParent := nil;
  Animations[Index].Keyframes := nil;
end;

procedure TElementAnimations.RemoveAnimation(Index: Integer);
var
  Position: Integer;
begin
  ClearAnimation(Index);
  Animations[Index].Easing.Release;
  for Position := Index to High(Animations) - 1 do
    Animations[Position] := Animations[Position + 1];
  SetLength(Animations, Length(Animations) - 1);
end;

procedure TElementAnimations.RemoveTransition(Index: Integer);
var
  Position: Integer;
begin
  ReleaseComputed(Transitions[Index].StartValue);
  ReleaseComputed(Transitions[Index].EndValue);
  Transitions[Index].Easing.Release;
  for Position := Index to High(Transitions) - 1 do
    Transitions[Position] := Transitions[Position + 1];
  SetLength(Transitions, Length(Transitions) - 1);
end;

destructor TElementAnimations.Destroy;
begin
  while Length(Animations) > 0 do
    RemoveAnimation(High(Animations));
  while Length(Transitions) > 0 do
    RemoveTransition(High(Transitions));
  inherited Destroy;
end;

function TElementAnimations.HasEffects: Boolean;
begin
  Result := (Length(Animations) > 0) or (Length(Transitions) > 0);
end;

{ ---- reading the animation properties ---- }

{ The Index-th item of a comma list (repeating), the value itself when
  it is no list; nil for none. }
function ListItem(const Value: TCssComputedValue; Index: Integer): TCssValue;
var
  Data: TCssValue;
begin
  Result := nil;
  if Value.Kind <> cvValue then
    Exit;
  Data := Value.Data;
  if Data = nil then
    Exit;
  if (Data.Kind = vkList) and (Data.Separator = lsComma) then
  begin
    if Data.Count = 0 then
      Exit;
    Result := Data.Items[Index mod Data.Count];
  end
  else
    Result := Data;
end;

function ListCount(const Value: TCssComputedValue): Integer;
begin
  Result := 0;
  if (Value.Kind <> cvValue) or (Value.Data = nil) then
    Exit;
  if (Value.Data.Kind = vkList) and (Value.Data.Separator = lsComma) then
    Result := Value.Data.Count
  else
    Result := 1;
end;

{ A time in milliseconds. }
function TimeOf(Value: TCssValue): Double;
begin
  Result := 0;
  if (Value <> nil) and (Value.Kind = vkDimension) then
    Result := Value.Number * CanonicalFactor(Value.UnitValue) * 1000;
end;

function KeywordItem(const Value: TCssComputedValue; Index: Integer; Default: TCssKeyword): TCssKeyword;
var
  Item: TCssValue;
begin
  Result := Default;
  if Value.Kind = cvKeyword then
    Exit(TCssKeyword(Value.Keyword));
  Item := ListItem(Value, Index);
  if (Item <> nil) and (Item.Kind = vkKeyword) then
    Result := Item.Keyword;
end;

{ The names of animation-name ('' for none). }
function AnimationNames(Style: TCssComputedStyle): TStringArray;
var
  Value: PCssComputedValue;
  Index: Integer;
  Item: TCssValue;
begin
  Result := nil;
  Value := Style.Value(cpAnimationName);
  for Index := 0 to ListCount(Value^) - 1 do
  begin
    Item := ListItem(Value^, Index);
    SetLength(Result, Length(Result) + 1);
    if (Item <> nil) and (Item.Kind in [vkCustomIdent, vkString]) then
      Result[High(Result)] := Item.Text
    else
      Result[High(Result)] := '';
  end;
end;

function HasTransitions(Style: TCssComputedStyle): Boolean;
var
  Value: PCssComputedValue;
  Index: Integer;
begin
  Result := False;
  Value := Style.Value(cpTransitionDuration);
  for Index := 0 to ListCount(Value^) - 1 do
    if TimeOf(ListItem(Value^, Index)) > 0 then
      Exit(True);
end;

function HasAnimationNames(Style: TCssComputedStyle): Boolean;
var
  Names: TStringArray;
  Index: Integer;
begin
  Names := AnimationNames(Style);
  for Index := 0 to High(Names) do
    if Names[Index] <> '' then
      Exit(True);
  Result := False;
end;

{ ---- TStyleAnimations ---- }

constructor TStyleAnimations.Create(Engine: TCssStyleEngine);
begin
  inherited Create;
  FEngine := Engine;
  FClock := @SystemClock;
end;

function TStyleAnimations.SystemClock: Double;
begin
  Result := GetTickCount64;
end;

procedure TStyleAnimations.AddActive(Element: TElement);
var
  Index: Integer;
begin
  for Index := 0 to High(FActive) do
    if FActive[Index] = Element then
      Exit;
  SetLength(FActive, Length(FActive) + 1);
  FActive[High(FActive)] := Element;
end;

procedure TStyleAnimations.RemoveActive(Element: TElement);
var
  Index: Integer;
begin
  for Index := 0 to High(FActive) do
    if FActive[Index] = Element then
    begin
      FActive[Index] := FActive[High(FActive)];
      SetLength(FActive, Length(FActive) - 1);
      Exit;
    end;
end;

procedure TStyleAnimations.QueueEvent(Element: TElement; Kind: TAnimationEventKind; const Name: string;
  Elapsed: Double);
begin
  if FEventCount >= Length(FEvents) then
    SetLength(FEvents, FEventCount * 2 + 8);
  FEvents[FEventCount].Element := Element;
  FEvents[FEventCount].Kind := Kind;
  FEvents[FEventCount].Name := Name;
  FEvents[FEventCount].ElapsedTime := Elapsed / 1000;
  Inc(FEventCount);
end;

function TStyleAnimations.TakeEvents: TPendingAnimationEventArray;
begin
  Result := Copy(FEvents, 0, FEventCount);
  FEventCount := 0;
end;

function TStyleAnimations.Running: Boolean;
begin
  Result := Length(FActive) > 0;
end;

procedure TStyleAnimations.MarkDue;
var
  Index: Integer;
begin
  for Index := 0 to High(FActive) do
    MarkAnimationDirty(FActive[Index]);
end;

procedure TStyleAnimations.ElementRemoved(Element: TElement);
begin
  RemoveActive(Element);
end;

{ ---- the animations of one element ---- }

{ The animation list of NewBase onto State's (kept by name and place). }
procedure UpdateAnimations(State: TElementAnimations; Style: TCssComputedStyle; Now: Double;
  Animations: TStyleAnimations; Element: TElement);
var
  Names: TStringArray;
  Kept: array of TRunningAnimation;
  Index, Found, Search: Integer;
  Running: TRunningAnimation;
  Item: TCssValue;
  Paused: Boolean;
begin
  Names := AnimationNames(Style);
  Kept := nil;
  for Index := 0 to High(Names) do
  begin
    if Names[Index] = '' then
      Continue;
    Found := -1;
    for Search := 0 to High(State.Animations) do
      if State.Animations[Search].Name = Names[Index] then
      begin
        Found := Search;
        Break;
      end;
    if Found >= 0 then
    begin
      Running := State.Animations[Found];
      { Taken over (not released below). }
      State.Animations[Found].Name := '';
      State.Animations[Found].Easing := nil;
      State.Animations[Found].KeyframeStyles := nil;
      State.Animations[Found].KeyframesParent := nil;
    end
    else
    begin
      Running := Default(TRunningAnimation);
      Running.Name := Names[Index];
      Running.StartTime := Now;
      Running.LastIteration := 0;
    end;
    Running.Duration := TimeOf(ListItem(Style.Value(cpAnimationDuration)^, Index));
    Running.Delay := TimeOf(ListItem(Style.Value(cpAnimationDelay)^, Index));
    Item := ListItem(Style.Value(cpAnimationIterationCount)^, Index);
    Running.Iterations := 1;
    if Item <> nil then
    begin
      if Item.IsKeyword(kwInfinite) then
        Running.Iterations := Infinity
      else if Item.Kind in [vkNumber, vkInteger] then
        Running.Iterations := Max(0, Item.Number);
    end;
    Running.Direction := KeywordItem(Style.Value(cpAnimationDirection)^, Index, kwNormal);
    Running.FillMode := KeywordItem(Style.Value(cpAnimationFillMode)^, Index, kwNone);
    Running.Easing.Release;
    Running.Easing := ListItem(Style.Value(cpAnimationTimingFunction)^, Index);
    if Running.Easing <> nil then
      Running.Easing.AddRef;
    Paused := KeywordItem(Style.Value(cpAnimationPlayState)^, Index, kwRunning) = kwPaused;
    if Paused and not Running.Paused then
    begin
      Running.Paused := True;
      Running.PausedAt := Now;
    end
    else if not Paused and Running.Paused then
    begin
      Running.StartTime := Running.StartTime + (Now - Running.PausedAt);
      Running.Paused := False;
    end;
    SetLength(Kept, Length(Kept) + 1);
    Kept[High(Kept)] := Running;
  end;
  { What is no longer named is cancelled. }
  for Index := High(State.Animations) downto 0 do
  begin
    if (State.Animations[Index].Name <> '') and State.Animations[Index].Started and
      not State.Animations[Index].Ended then
      Animations.QueueEvent(Element, aeAnimationCancel, State.Animations[Index].Name, 0);
    State.RemoveAnimation(Index);
  end;
  State.Animations := Kept;
end;

{ The keyframes' styles of an animation under ParentStyle (made again
  when the parent's style or the rule changed). }
procedure PrepareKeyframes(var Running: TRunningAnimation; Engine: TCssStyleEngine; ParentStyle: TCssComputedStyle);
var
  Rule: TCssKeyframesRule;
  Index: Integer;
begin
  Rule := Engine.FindKeyframes(Running.Name);
  if (Rule = Running.Keyframes) and (Running.KeyframesParent = ParentStyle) and (Rule <> nil) then
    Exit;
  for Index := 0 to High(Running.KeyframeStyles) do
    Running.KeyframeStyles[Index].Release;
  Running.KeyframeStyles := nil;
  Running.KeyframesParent.Release;
  Running.KeyframesParent := ParentStyle.AddRef;
  Running.Keyframes := Rule;
  if Rule = nil then
    Exit;
  SetLength(Running.KeyframeStyles, Length(Rule.Rules));
  for Index := 0 to High(Rule.Rules) do
    Running.KeyframeStyles[Index] := Engine.ComputeBlockStyle(TCssKeyframeRule(Rule.Rules[Index]).Declarations,
      ParentStyle);
end;

type
  TKeyframePoint = record
    Offset: Double;
    Value: PCssComputedValue;
    Color: TCssColor;
  end;

function DeclaresProperty(Block: TCssDeclarationBlock; Id: TCssPropertyId): Boolean;
begin
  Result := Block.Find(Id) <> nil;
end;

{ The value of Id at an iteration progress from the keyframes, the base
  style standing in for missing 0% and 100% frames. }
function KeyframeValue(const Running: TRunningAnimation; Id: TCssPropertyId; Base: TCssComputedStyle;
  Progress: Double; out Value: TCssComputedValue): Boolean;
var
  Points: array of TKeyframePoint;
  Index, Offset, Before, After: Integer;
  Rule: TCssKeyframeRule;
  Local, Span: Double;
  Swap: TKeyframePoint;

  procedure AddPoint(At: Double; Source: TCssComputedStyle);
  begin
    SetLength(Points, Length(Points) + 1);
    Points[High(Points)].Offset := At;
    Points[High(Points)].Value := Source.Value(Id);
    Points[High(Points)].Color := Source.Color;
  end;

begin
  Result := False;
  Points := nil;
  for Index := 0 to High(Running.Keyframes.Rules) do
  begin
    Rule := TCssKeyframeRule(Running.Keyframes.Rules[Index]);
    if not DeclaresProperty(Rule.Declarations, Id) then
      Continue;
    for Offset := 0 to High(Rule.Offsets) do
      AddPoint(Rule.Offsets[Offset], Running.KeyframeStyles[Index]);
  end;
  if Length(Points) = 0 then
    Exit;
  { In offset order (insertion sort: few frames), later rules after
    earlier ones at one offset. }
  for Index := 1 to High(Points) do
  begin
    Offset := Index;
    while (Offset > 0) and (Points[Offset - 1].Offset > Points[Offset].Offset) do
    begin
      Swap := Points[Offset - 1];
      Points[Offset - 1] := Points[Offset];
      Points[Offset] := Swap;
      Dec(Offset);
    end;
  end;
  if Points[0].Offset > 0 then
  begin
    SetLength(Points, Length(Points) + 1);
    for Index := High(Points) downto 1 do
      Points[Index] := Points[Index - 1];
    Points[0].Offset := 0;
    Points[0].Value := Base.Value(Id);
    Points[0].Color := Base.Color;
  end;
  if Points[High(Points)].Offset < 1 then
    AddPoint(1, Base);
  Before := 0;
  for Index := 0 to High(Points) do
    if Points[Index].Offset <= Progress then
      Before := Index;
  After := Before;
  if (Before < High(Points)) and (Points[Before].Offset <= Progress) then
    After := Before + 1;
  if After = Before then
  begin
    Value := Points[Before].Value^;
    AddRefComputed(Value);
    Exit(True);
  end;
  Span := Points[After].Offset - Points[Before].Offset;
  if Span <= 0 then
    Local := 1
  else
    Local := (Progress - Points[Before].Offset) / Span;
  Local := EasedProgress(Running.Easing, Local);
  if not InterpolateComputed(Id, Points[Before].Value^, Points[After].Value^, Points[Before].Color,
    Points[After].Color, Local, Value) then
  begin
    if Local < 0.5 then
      Value := Points[Before].Value^
    else
      Value := Points[After].Value^;
    AddRefComputed(Value);
  end;
  Result := True;
end;

{ The iteration progress of an animation at Now, or False when it has no
  effect then (before its delay without backwards fill, after its end
  without forwards fill). Ended: the active interval is over. }
function AnimationProgress(var Running: TRunningAnimation; Now: Double; out Progress: Double;
  out Iteration: Int64; out Ended: Boolean): Boolean;
var
  Elapsed, Total, Overall: Double;
  Reversed: Boolean;
begin
  Result := False;
  Progress := 0;
  Iteration := 0;
  Ended := False;
  if Running.Paused then
    Now := Running.PausedAt;
  Elapsed := Now - Running.StartTime - Running.Delay;
  if IsInfinite(Running.Iterations) then
    Total := Infinity
  else
    Total := Running.Duration * Running.Iterations;
  if Elapsed < 0 then
  begin
    if not KeywordIn(Running.FillMode, [kwBackwards, kwBoth]) then
      Exit;
    Overall := 0;
  end
  else if (Total <= 0) or (not IsInfinite(Total) and (Elapsed >= Total)) then
  begin
    Ended := True;
    if not KeywordIn(Running.FillMode, [kwForwards, kwBoth]) then
      Exit;
    Overall := Running.Iterations;
    if IsInfinite(Overall) then
      Overall := 1;
  end
  else if Running.Duration <= 0 then
    Overall := 0
  else
    Overall := Elapsed / Running.Duration;
  Iteration := Trunc(Overall);
  Progress := Overall - Iteration;
  { An end on a whole iteration shows that iteration's end. }
  if Ended and (Progress = 0) and (Overall > 0) then
  begin
    Progress := 1;
    Dec(Iteration);
  end;
  Reversed := False;
  case Running.Direction of
    kwReverse: Reversed := True;
    kwAlternate: Reversed := Odd(Iteration);
    kwAlternateReverse: Reversed := not Odd(Iteration);
  end;
  if Reversed then
    Progress := 1 - Progress;
  Result := True;
end;

{ The longhands transition-property's item names ('' none, 'all'). }
function TransitionedAt(Style: TCssComputedStyle; Id: TCssPropertyId; out Index: Integer): Boolean;
var
  Value: PCssComputedValue;
  Count, Position, Longhand: Integer;
  Item: TCssValue;
  Named: TCssPropertyId;
  Longhands: TCssPropertyIdArray;
begin
  Result := False;
  Index := -1;
  Value := Style.Value(cpTransitionProperty);
  if Value^.Kind = cvKeyword then
  begin
    if TCssKeyword(Value^.Keyword) = kwAll then
    begin
      Index := 0;
      Result := True;
    end;
    Exit;
  end;
  Count := ListCount(Value^);
  for Position := Count - 1 downto 0 do
  begin
    Item := ListItem(Value^, Position);
    if Item = nil then
      Continue;
    if Item.IsKeyword(kwAll) then
    begin
      Index := Position;
      Exit(True);
    end;
    if Item.Kind <> vkCustomIdent then
      Continue;
    Named := PropertyByName(Item.Text);
    if Named = Id then
    begin
      Index := Position;
      Exit(True);
    end;
    if (Named > cpInvalid) and IsShorthand(Named) then
    begin
      Longhands := ShorthandLonghands(Named);
      for Longhand := 0 to High(Longhands) do
        if Longhands[Longhand] = Id then
        begin
          Index := Position;
          Exit(True);
        end;
    end;
  end;
end;

{ Transitions of the properties whose cascaded values changed. }
procedure UpdateTransitions(State: TElementAnimations; OldBase, OldShown, NewBase: TCssComputedStyle; Now: Double;
  Animations: TStyleAnimations; Element: TElement);
var
  Id: TCssPropertyId;
  Index, Found, Search: Integer;
  OldValue, NewValue, Shown: PCssComputedValue;
  Duration: Double;
  Running: TRunningTransition;
begin
  for Id := Succ(cpInvalid) to High(TCssPhysicalId) do
  begin
    if not IsAnimatable(Id) then
      Continue;
    OldValue := OldBase.Value(Id);
    NewValue := NewBase.Value(Id);
    if SameComputed(OldValue^, NewValue^) then
      Continue;
    Found := -1;
    for Search := 0 to High(State.Transitions) do
      if State.Transitions[Search].Id = Id then
        Found := Search;
    if (Found >= 0) and SameComputed(State.Transitions[Found].EndValue, NewValue^) then
      Continue;
    Duration := 0;
    if TransitionedAt(NewBase, Id, Index) then
      Duration := TimeOf(ListItem(NewBase.Value(cpTransitionDuration)^, Index));
    if Found >= 0 then
    begin
      if State.Transitions[Found].Started then
        Animations.QueueEvent(Element, aeTransitionCancel, PropertyName(Id), 0);
      State.RemoveTransition(Found);
    end;
    if Duration <= 0 then
      Continue;
    Shown := OldShown.Value(Id);
    if SameComputed(Shown^, NewValue^) then
      Continue;
    Running := Default(TRunningTransition);
    Running.Id := Id;
    Running.StartValue := Shown^;
    AddRefComputed(Running.StartValue);
    Running.EndValue := NewValue^;
    AddRefComputed(Running.EndValue);
    Running.StartColor := OldShown.Color;
    Running.EndColor := NewBase.Color;
    Running.StartTime := Now;
    Running.Duration := Duration;
    Running.Delay := TimeOf(ListItem(NewBase.Value(cpTransitionDelay)^, Index));
    Running.Easing := ListItem(NewBase.Value(cpTransitionTimingFunction)^, Index);
    if Running.Easing <> nil then
      Running.Easing.AddRef;
    SetLength(State.Transitions, Length(State.Transitions) + 1);
    State.Transitions[High(State.Transitions)] := Running;
    Animations.QueueEvent(Element, aeTransitionRun, PropertyName(Id), 0);
  end;
end;

function TStyleAnimations.Animate(Element: TElement; OldBase, OldShown, NewBase,
  ParentStyle: TCssComputedStyle): TCssComputedStyle;
var
  Data: PNodeData;
  State: TElementAnimations;
  Now, Progress, Local: Double;
  Overrides: TCssValueOverrideArray;
  OverrideCount, Index, Rule, Slot: Integer;
  Iteration: Int64;
  Ended, NewEnd: Boolean;
  Value: TCssComputedValue;
  Id: TCssPropertyId;
  Block: TCssDeclarationBlock;
  Declaration: PCssDeclaration;

  procedure SetOverride(PropertyId: TCssPropertyId; const NewValue: TCssComputedValue);
  var
    Position: Integer;
  begin
    for Position := 0 to OverrideCount - 1 do
      if Overrides[Position].Id = PropertyId then
      begin
        ReleaseComputed(Overrides[Position].Value);
        Overrides[Position].Value := NewValue;
        Exit;
      end;
    if OverrideCount >= Length(Overrides) then
      SetLength(Overrides, OverrideCount * 2 + 8);
    Overrides[OverrideCount].Id := PropertyId;
    Overrides[OverrideCount].Value := NewValue;
    Inc(OverrideCount);
  end;

begin
  Data := NodeDataOf(Element);
  State := TElementAnimations(Data^.Animations);
  { Nothing to do for the elements (nearly all) without any. }
  if (State = nil) and not HasAnimationNames(NewBase) and
    not ((OldBase <> nil) and (OldBase <> NewBase) and HasTransitions(NewBase)) then
  begin
    Data^.BaseStyle.Release;
    Data^.BaseStyle := nil;
    Exit(NewBase.AddRef);
  end;
  Now := FClock();
  if State = nil then
  begin
    State := TElementAnimations.Create;
    Data^.Animations := State;
  end;
  if (OldBase <> NewBase) or (Length(State.Animations) > 0) then
    UpdateAnimations(State, NewBase, Now, Self, Element);
  if (OldBase <> nil) and (OldShown <> nil) and (OldBase <> NewBase) then
    UpdateTransitions(State, OldBase, OldShown, NewBase, Now, Self, Element);
  Overrides := nil;
  OverrideCount := 0;
  { Animations first: transitions win over them. }
  for Index := 0 to High(State.Animations) do
  begin
    PrepareKeyframes(State.Animations[Index], FEngine, ParentStyle);
    if State.Animations[Index].Keyframes = nil then
      Continue;
    NewEnd := False;
    if AnimationProgress(State.Animations[Index], Now, Progress, Iteration, Ended) or Ended then
    begin
      if not State.Animations[Index].Started and (Now - State.Animations[Index].StartTime >=
        State.Animations[Index].Delay) then
      begin
        State.Animations[Index].Started := True;
        QueueEvent(Element, aeAnimationStart, State.Animations[Index].Name, 0);
      end;
      if not Ended and (Iteration > State.Animations[Index].LastIteration) then
      begin
        State.Animations[Index].LastIteration := Iteration;
        QueueEvent(Element, aeAnimationIteration, State.Animations[Index].Name,
          Iteration * State.Animations[Index].Duration);
      end;
      if Ended and not State.Animations[Index].Ended then
      begin
        State.Animations[Index].Ended := True;
        NewEnd := True;
      end;
    end;
    if NewEnd then
      QueueEvent(Element, aeAnimationEnd, State.Animations[Index].Name,
        State.Animations[Index].Duration * Min(State.Animations[Index].Iterations, 1E9));
    if not AnimationProgress(State.Animations[Index], Now, Progress, Iteration, Ended) then
      Continue;
    for Rule := 0 to High(State.Animations[Index].Keyframes.Rules) do
    begin
      Block := TCssKeyframeRule(State.Animations[Index].Keyframes.Rules[Rule]).Declarations;
      for Slot := 0 to Block.Count - 1 do
      begin
        Declaration := Block.Item(Slot);
        Id := Declaration^.Id;
        if not IsAnimatable(Id) then
          Continue;
        if KeyframeValue(State.Animations[Index], Id, NewBase, Progress, Value) then
          SetOverride(Id, Value);
      end;
    end;
  end;
  for Index := High(State.Transitions) downto 0 do
  begin
    Progress := Now - State.Transitions[Index].StartTime - State.Transitions[Index].Delay;
    if Progress >= State.Transitions[Index].Duration then
    begin
      QueueEvent(Element, aeTransitionEnd, PropertyName(State.Transitions[Index].Id),
        State.Transitions[Index].Duration);
      State.RemoveTransition(Index);
      Continue;
    end;
    if Progress < 0 then
      Local := 0
    else
    begin
      if not State.Transitions[Index].Started then
      begin
        State.Transitions[Index].Started := True;
        QueueEvent(Element, aeTransitionStart, PropertyName(State.Transitions[Index].Id), 0);
      end;
      Local := EasedProgress(State.Transitions[Index].Easing, Progress / State.Transitions[Index].Duration);
    end;
    if not InterpolateComputed(State.Transitions[Index].Id, State.Transitions[Index].StartValue,
      State.Transitions[Index].EndValue, State.Transitions[Index].StartColor, State.Transitions[Index].EndColor,
      Local, Value) then
    begin
      if Local < 0.5 then
        Value := State.Transitions[Index].StartValue
      else
        Value := State.Transitions[Index].EndValue;
      AddRefComputed(Value);
    end;
    SetOverride(State.Transitions[Index].Id, Value);
  end;
  { Still running: frames wanted. Finished animations that fill keep
    their state (and their style) without frames. }
  Ended := True;
  for Index := 0 to High(State.Animations) do
    if not State.Animations[Index].Ended and (State.Animations[Index].Keyframes <> nil) and
      not State.Animations[Index].Paused then
      Ended := False;
  if Length(State.Transitions) > 0 then
    Ended := False;
  if Ended then
    RemoveActive(Element)
  else
    AddActive(Element);
  if not State.HasEffects then
  begin
    Data^.Animations := nil;
    State.Free;
    Data^.BaseStyle.Release;
    Data^.BaseStyle := nil;
    Exit(NewBase.AddRef);
  end;
  if Data^.BaseStyle <> NewBase then
  begin
    Data^.BaseStyle.Release;
    Data^.BaseStyle := NewBase.AddRef;
  end;
  if OverrideCount = 0 then
    Exit(NewBase.AddRef);
  Result := StyleWithOverrides(NewBase, Overrides, OverrideCount);
end;

end.

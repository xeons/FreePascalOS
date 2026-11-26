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
  The natives of platform/77-animations.js (Web Animations): keyframe
  effects handed to styling (Web.Style.ScriptAnimations), their
  progress each frame, easing functions evaluated by libcss, and the
  element's CSS animations and transitions as the layout knows them
  (CSSAnimation and CSSTransition objects), with pause, play, cancel
  and seeking.
}
unit Web.Script.NativeAnimations;

{$mode objfpc}
{$H+}

interface

uses
  Js.Objects,
  Web.Bindings.Context;

procedure DefineAnimationNatives(Context: TBindingContext; Natives: TJsObject);

implementation

uses
  SysUtils,
  Js.Values,
  Js.Functions,
  Web.Dom,
  Web.Bindings.Types,
  Web.ScriptEnvironment,
  Web.Style.ScriptAnimations;

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue; inline;
begin
  if Index < Count then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

function ElementArg(Context: TBindingContext; Args: PJsValueArray; Count, Index: Integer): TElement;
var
  Native: TObject;
begin
  Native := Context.Unwrap(Arg(Args, Count, Index), InterfaceElement);
  if Native is TElement then
    Result := TElement(Native)
  else
    Result := nil;
end;

function NumberArg(Context: TBindingContext; Args: PJsValueArray; Count, Index: Integer): Double;
begin
  Result := Context.Engine.ToNumber(Arg(Args, Count, Index));
end;

function ArrayLength(Context: TBindingContext; Value: TJsValue): Integer;
begin
  Result := Trunc(Context.Engine.ToNumber(Context.Engine.GetProperty(Value, 'length')));
end;

function ArrayItem(Context: TBindingContext; Value: TJsValue; Index: Integer): TJsValue;
begin
  Result := Context.Engine.GetProperty(Value, IntToStr(Index));
end;

{ animationKeyframes(element, handle, offsets, easings, declarations) }
function NativeKeyframes(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Element: TElement;
  Offsets: array of Double;
  Easings, Declarations: array of string;
  Count, Index: Integer;
  OffsetList, EasingList, DeclarationList: TJsValue;
begin
  Result := JsUndefined;
  Element := ElementArg(Context, Args, ArgCount, 0);
  if Element = nil then
    Exit;
  OffsetList := Arg(Args, ArgCount, 2);
  EasingList := Arg(Args, ArgCount, 3);
  DeclarationList := Arg(Args, ArgCount, 4);
  Count := ArrayLength(Context, OffsetList);
  Offsets := nil;
  Easings := nil;
  Declarations := nil;
  SetLength(Offsets, Count);
  SetLength(Easings, Count);
  SetLength(Declarations, Count);
  for Index := 0 to Count - 1 do
  begin
    Offsets[Index] := Context.Engine.ToNumber(ArrayItem(Context, OffsetList, Index));
    Easings[Index] := ValueToText(Context.Engine.Realm, ArrayItem(Context, EasingList, Index));
    Declarations[Index] := ValueToText(Context.Engine.Realm, ArrayItem(Context, DeclarationList, Index));
  end;
  SetEffectKeyframes(Element, Trunc(NumberArg(Context, Args, ArgCount, 1)), Offsets, Easings, Declarations);
end;

{ animationProgress(element, handle, inEffect, progress) }
function NativeProgress(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Element: TElement;
begin
  Result := JsUndefined;
  Element := ElementArg(Context, Args, ArgCount, 0);
  if Element = nil then
    Exit;
  SetEffectProgress(Element, Trunc(NumberArg(Context, Args, ArgCount, 1)),
    Arg(Args, ArgCount, 2) = JsTrue, NumberArg(Context, Args, ArgCount, 3));
end;

{ animationRemove(element, handle) }
function NativeRemove(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Element: TElement;
begin
  Result := JsUndefined;
  Element := ElementArg(Context, Args, ArgCount, 0);
  if Element <> nil then
    RemoveEffect(Element, Trunc(NumberArg(Context, Args, ArgCount, 1)));
end;

{ easeProgress(easing, progress) }
function NativeEase(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := JsNumber(EaseProgress(ValueToText(Context.Engine.Realm, Arg(Args, ArgCount, 0)),
    NumberArg(Context, Args, ArgCount, 1)));
end;

{ cssAnimations(element): [{transition, name, localTime, delay, duration,
  iterations, direction, fill, paused, ended}] }
function NativeCssAnimations(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Element: TElement;
  Infos: TScriptCssAnimationArray;
  Items: array of TJsValue;
  Index: Integer;
  Item: TJsValue;
begin
  Element := ElementArg(Context, Args, ArgCount, 0);
  Infos := nil;
  if (Element <> nil) and (Context.Environment.Layout <> nil) and Element.IsConnected then
    Infos := Context.Environment.Layout.CssAnimations(Element);
  Items := nil;
  SetLength(Items, Length(Infos));
  for Index := 0 to High(Infos) do
  begin
    Item := JsObjectValue(Context.Engine.NewObject);
    Context.Engine.SetProperty(Item, 'transition', JsBoolean(Infos[Index].IsTransition));
    Context.Engine.SetProperty(Item, 'name', Context.TextValue(Infos[Index].Name));
    Context.Engine.SetProperty(Item, 'localTime', JsNumber(Infos[Index].LocalTime));
    Context.Engine.SetProperty(Item, 'delay', JsNumber(Infos[Index].Delay));
    Context.Engine.SetProperty(Item, 'duration', JsNumber(Infos[Index].Duration));
    Context.Engine.SetProperty(Item, 'iterations', JsNumber(Infos[Index].Iterations));
    Context.Engine.SetProperty(Item, 'direction', Context.TextValue(Infos[Index].Direction));
    Context.Engine.SetProperty(Item, 'fill', Context.TextValue(Infos[Index].Fill));
    Context.Engine.SetProperty(Item, 'paused', JsBoolean(Infos[Index].Paused));
    Context.Engine.SetProperty(Item, 'ended', JsBoolean(Infos[Index].Ended));
    Items[Index] := Item;
  end;
  Result := Context.NewArray(Items);
end;

{ cssAnimationControl(element, isTransition, name, action, value) with
  action "pause", "play", "cancel" or "seek". }
function NativeCssControl(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Element: TElement;
  ActionText: string;
  Action: TScriptCssAnimationAction;
begin
  Result := JsUndefined;
  Element := ElementArg(Context, Args, ArgCount, 0);
  if (Element = nil) or (Context.Environment.Layout = nil) then
    Exit;
  ActionText := ValueToText(Context.Engine.Realm, Arg(Args, ArgCount, 3));
  if ActionText = 'pause' then
    Action := scaPause
  else if ActionText = 'play' then
    Action := scaPlay
  else if ActionText = 'cancel' then
    Action := scaCancel
  else
    Action := scaSeek;
  Context.Environment.Layout.ControlCssAnimation(Element, Arg(Args, ArgCount, 1) = JsTrue,
    ValueToText(Context.Engine.Realm, Arg(Args, ArgCount, 2)), Action, NumberArg(Context, Args, ArgCount, 4));
end;

type
  TAnimationNative = function(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;

const
  AnimationNativeCount = 6;
  AnimationNativeNames: array[0..AnimationNativeCount - 1] of string = ('animationKeyframes', 'animationProgress',
    'animationRemove', 'easeProgress', 'cssAnimations', 'cssAnimationControl');
  AnimationNativeLengths: array[0..AnimationNativeCount - 1] of Integer = (5, 4, 2, 2, 1, 5);
  AnimationNativeRoutines: array[0..AnimationNativeCount - 1] of TAnimationNative = (@NativeKeyframes,
    @NativeProgress, @NativeRemove, @NativeEase, @NativeCssAnimations, @NativeCssControl);

function AnimationNativeEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
begin
  Context := ContextOfRealm(R);
  try
    Result := AnimationNativeRoutines[Callee.Magic](Context, Args, ArgCount);
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

procedure DefineAnimationNatives(Context: TBindingContext; Natives: TJsObject);
var
  Index: Integer;
begin
  for Index := 0 to AnimationNativeCount - 1 do
    Context.Engine.DefineFunction(Natives, AnimationNativeNames[Index], @AnimationNativeEntry,
      AnimationNativeLengths[Index], Index);
end;

end.

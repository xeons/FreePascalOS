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
  The platform scripts (userland/lib/web/platform/*.js, built into
  Web.Script.PlatformSources) and the native functions they are given.

  Some window interfaces are mostly object juggling and promises over a
  few engine services (Performance, Storage, fetch's Headers, Request
  and Response, XMLHttpRequest, Blob, the observers): they are written in
  JavaScript, run as built-ins when a window is made (their functions
  read as native code), and reach the engine only through the natives
  object here - the clock, the storage areas, the media environment,
  randomness and digests, fetching, layout. Each script is a function
  of (natives, global, internal), run in file name order; internal is
  shared between them.

  The natives object is kept as the window's SingletonPlatformNatives;
  scripts set callbacks on it (onAnimationFrame, onFetchEvent,
  onMediaChanged) that the engine calls through CallPlatformCallback.
}
unit Web.Script.Natives;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Bindings.Context;

{ Runs the platform scripts in Context's realm. }
procedure InstallPlatform(Context: TBindingContext);
{ Calls natives[Name](Args) if a script set it; False if it is not set
  or threw (reported). }
function CallPlatformCallback(Context: TBindingContext; const Name: string; const Args: array of TJsValue): Boolean;

implementation

uses
  SysUtils,
  Js.Objects,
  Js.Functions,
  Js.Engine,
  Css.MediaQueries,
  Css.Supports,
  Crypto.Digests,
  Crypto.Random,
  Web.Storage,
  Web.ScriptEnvironment,
  Web.Script.PlatformSources,
  Web.Script.NativeFetch;

const
  LocalKind = 0;

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue; inline;
begin
  if Index < Count then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

function ArgText(Context: TBindingContext; Args: PJsValueArray; Count, Index: Integer): string;
begin
  Result := ValueToText(Context.Engine.Realm, Arg(Args, Count, Index));
end;

function ArgInteger(Context: TBindingContext; Args: PJsValueArray; Count, Index: Integer): Integer;
begin
  Result := Trunc(Context.Engine.ToNumber(Arg(Args, Count, Index)));
end;

type
  TNativeRoutine = function(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;

function NativeNow(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := JsNumber(Context.Now);
end;

function NativeTimeOrigin(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := JsNumber(Context.TimeOriginUnix);
end;

function NativeNavigationTiming(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Timing: TScriptNavigationTiming;
  Target: TJsValue;
  Origin: QWord;

  procedure Moment(const Name: string; Ticks: QWord);
  begin
    if Ticks = 0 then
      Context.Engine.SetProperty(Target, Name, JsNumber(0))
    else if Ticks <= Origin then
      Context.Engine.SetProperty(Target, Name, JsNumber(0.1))
    else
      Context.Engine.SetProperty(Target, Name, JsNumber(Ticks - Origin));
  end;

begin
  Timing := Context.Environment.NavigationTiming(Context);
  Origin := Context.TimeOriginTicks;
  Target := JsObjectValue(Context.Engine.NewObject);
  Context.Engine.SetProperty(Target, 'type', Context.TextValue(Timing.Kind));
  Context.Engine.SetProperty(Target, 'redirectCount', JsInteger(Timing.RedirectCount));
  Moment('fetchStart', Timing.FetchStart);
  if Timing.FetchStart = 0 then
    Context.Engine.SetProperty(Target, 'fetchStart', JsNumber(0));
  Moment('requestStart', Timing.RequestStart);
  Moment('responseStart', Timing.ResponseStart);
  Moment('responseEnd', Timing.ResponseEnd);
  Moment('domInteractive', Timing.DomInteractive);
  Moment('domContentLoadedEventStart', Timing.DomContentLoadedEventStart);
  Moment('domContentLoadedEventEnd', Timing.DomContentLoadedEventEnd);
  Moment('domComplete', Timing.DomComplete);
  Moment('loadEventStart', Timing.LoadEventStart);
  Moment('loadEventEnd', Timing.LoadEventEnd);
  Context.Engine.SetProperty(Target, 'nextHopProtocol', Context.TextValue(Timing.NextHopProtocol));
  Context.Engine.SetProperty(Target, 'transferSize', JsNumber(Timing.TransferSize));
  Context.Engine.SetProperty(Target, 'encodedBodySize', JsNumber(Timing.EncodedBodySize));
  Context.Engine.SetProperty(Target, 'decodedBodySize', JsNumber(Timing.DecodedBodySize));
  Context.Engine.SetProperty(Target, 'responseStatus', JsInteger(Timing.ResponseStatus));
  Result := Target;
end;

{ Storage }

function AreaOf(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TWebStorageArea;
begin
  Result := Context.Environment.StorageArea(Context, ArgInteger(Context, Args, ArgCount, 0) <> LocalKind);
end;

function NativeStorageAvailable(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := JsBoolean(AreaOf(Context, Args, ArgCount) <> nil);
end;

function NativeStorageLength(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Area: TWebStorageArea;
begin
  Area := AreaOf(Context, Args, ArgCount);
  if Area = nil then
    Exit(JsInteger(0));
  Result := JsInteger(Area.Count);
end;

function NativeStorageKey(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Area: TWebStorageArea;
  Index: Integer;
begin
  Area := AreaOf(Context, Args, ArgCount);
  Index := ArgInteger(Context, Args, ArgCount, 1);
  if (Area = nil) or (Index < 0) or (Index >= Area.Count) then
    Exit(JsUndefined);
  Result := Context.TextValue(Area.KeyAt(Index));
end;

function NativeStorageGet(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Area: TWebStorageArea;
  Value: string;
begin
  Area := AreaOf(Context, Args, ArgCount);
  if (Area = nil) or not Area.TryGet(ArgText(Context, Args, ArgCount, 1), Value) then
    Exit(JsUndefined);
  Result := Context.TextValue(Value);
end;

function NativeStorageSet(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Area: TWebStorageArea;
begin
  Area := AreaOf(Context, Args, ArgCount);
  if Area = nil then
    Exit(JsFalse);
  if not Area.SetItem(ArgText(Context, Args, ArgCount, 1), ArgText(Context, Args, ArgCount, 2)) then
    Exit(JsFalse);
  Context.Environment.StorageChanged(Context, Area);
  Result := JsTrue;
end;

function NativeStorageRemove(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Area: TWebStorageArea;
begin
  Area := AreaOf(Context, Args, ArgCount);
  if Area <> nil then
  begin
    Area.RemoveItem(ArgText(Context, Args, ArgCount, 1));
    Context.Environment.StorageChanged(Context, Area);
  end;
  Result := JsUndefined;
end;

function NativeStorageClear(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Area: TWebStorageArea;
begin
  Area := AreaOf(Context, Args, ArgCount);
  if Area <> nil then
  begin
    Area.Clear;
    Context.Environment.StorageChanged(Context, Area);
  end;
  Result := JsUndefined;
end;

{ The rest }

function NativeReportError(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Context.ReportException(Arg(Args, ArgCount, 0));
  Result := JsUndefined;
end;

function NativeRequestFrame(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := JsBoolean(Context.Environment.RequestAnimationFrame(Context));
end;

function NativeScreen(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Width, Height: Integer;
begin
  Width := Context.Environment.ScreenWidth;
  Height := Context.Environment.ScreenHeight;
  Result := JsObjectValue(Context.Engine.NewObject);
  Context.Engine.SetProperty(Result, 'width', JsInteger(Width));
  Context.Engine.SetProperty(Result, 'height', JsInteger(Height));
  Context.Engine.SetProperty(Result, 'availWidth', JsInteger(Width));
  Context.Engine.SetProperty(Result, 'availHeight', JsInteger(Height));
end;

function NativeMatchMedia(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  List: TCssMediaQueryList;
begin
  List := ParseMediaQueryText(ArgText(Context, Args, ArgCount, 0));
  try
    Result := JsBoolean(List.Matches(Context.Environment.MediaEnvironment));
  finally
    List.Free;
  end;
end;

function NativeNormalizeMedia(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  List: TCssMediaQueryList;
begin
  List := ParseMediaQueryText(ArgText(Context, Args, ArgCount, 0));
  try
    Result := Context.TextValue(List.Serialize);
  finally
    List.Free;
  end;
end;

function NativeCssSupports(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Text: string;
begin
  Text := ArgText(Context, Args, ArgCount, 0);
  if SupportsConditionText(Text) then
    Exit(JsTrue);
  { A bare declaration ("display: grid") is tested in parentheses. }
  Result := JsBoolean(SupportsConditionText('(' + Text + ')'));
end;

function NativeDigest(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Name: string;
  Algorithm: TDigestAlgorithm;
  Data: PByte;
  Length_: SizeInt;
  Output: TDigestOutput;
begin
  Name := ArgText(Context, Args, ArgCount, 0);
  if Name = 'SHA-1' then
    Algorithm := DigestSha1
  else if Name = 'SHA-384' then
    Algorithm := DigestSha384
  else if Name = 'SHA-512' then
    Algorithm := DigestSha512
  else
    Algorithm := DigestSha256;
  if not Context.Engine.BufferSourceData(Arg(Args, ArgCount, 1), Data, Length_) then
  begin
    Data := nil;
    Length_ := 0;
  end;
  ComputeDigest(Algorithm, Data, Length_, Output);
  Result := Context.Engine.NewUint8Array(@Output[0], DigestSize(Algorithm));
end;

function NativeRandomFill(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Data: PByte;
  Length_: SizeInt;
begin
  if Context.Engine.BufferSourceData(Arg(Args, ArgCount, 0), Data, Length_) and (Length_ > 0) then
    RandomBytes(Data, Length_);
  Result := JsUndefined;
end;

function NativeBeacon(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Data: PByte;
  Length_: SizeInt;
  Body: TBytes;
begin
  Body := nil;
  if Context.Engine.BufferSourceData(Arg(Args, ArgCount, 1), Data, Length_) and (Length_ > 0) then
  begin
    SetLength(Body, Length_);
    Move(Data^, Body[0], Length_);
  end;
  Context.Environment.SendBeacon(Context, ArgText(Context, Args, ArgCount, 0), Body,
    ArgText(Context, Args, ArgCount, 2));
  Result := JsUndefined;
end;

const
  NativeCount = 19;
  NativeNames: array[0..NativeCount - 1] of string = (
    'now',
    'timeOrigin',
    'navigationTiming',
    'storageAvailable',
    'storageLength',
    'storageKey',
    'storageGet',
    'storageSet',
    'storageRemove',
    'storageClear',
    'reportError',
    'requestFrame',
    'screen',
    'matchMedia',
    'normalizeMedia',
    'digest',
    'randomFill',
    'beacon',
    'cssSupports');
  NativeLengths: array[0..NativeCount - 1] of Integer = (0, 0, 0, 1, 1, 2, 2, 3, 2, 1, 1, 0, 0, 1, 1, 2, 1, 3, 1);
  NativeRoutines: array[0..NativeCount - 1] of TNativeRoutine = (
    @NativeNow,
    @NativeTimeOrigin,
    @NativeNavigationTiming,
    @NativeStorageAvailable,
    @NativeStorageLength,
    @NativeStorageKey,
    @NativeStorageGet,
    @NativeStorageSet,
    @NativeStorageRemove,
    @NativeStorageClear,
    @NativeReportError,
    @NativeRequestFrame,
    @NativeScreen,
    @NativeMatchMedia,
    @NativeNormalizeMedia,
    @NativeDigest,
    @NativeRandomFill,
    @NativeBeacon,
    @NativeCssSupports);

{ Every native: runs its routine in the realm's context; a Pascal
  exception becomes a script error. }
function NativeEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
begin
  Context := ContextOfRealm(R);
  try
    Result := NativeRoutines[Callee.Magic](Context, Args, ArgCount);
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

procedure DefineNatives(Context: TBindingContext; Natives: TJsObject);
var
  Index: Integer;
begin
  for Index := 0 to NativeCount - 1 do
    Context.Engine.DefineFunction(Natives, NativeNames[Index], @NativeEntry, NativeLengths[Index], Index);
  DefineFetchNatives(Context, Natives);
end;

procedure InstallPlatform(Context: TBindingContext);
var
  Engine: TJsEngine;
  Natives, Internal: TJsValue;
  Factory, Outcome: TJsValue;
  Index: Integer;
begin
  Engine := Context.Engine;
  Natives := JsObjectValue(Engine.NewObject);
  Context.SetSingleton(SingletonPlatformNatives, Natives);
  DefineNatives(Context, JsAsObject(Natives));
  Internal := JsObjectValue(Engine.NewObject);
  Context.SetSingleton(SingletonPlatformInternal, Internal);
  for Index := 0 to PlatformScriptCount - 1 do
  begin
    try
      Factory := Engine.EvaluateBuiltin(PlatformScriptSource(Index), 'platform/' + PlatformScriptNames[Index]);
      if not Context.CallFunction(Factory, JsUndefined, [Natives, JsObjectValue(Engine.GlobalObject), Internal],
        Outcome, 'platform/' + PlatformScriptNames[Index]) then
        Continue;
    except
      on Error: EJsError do
        Context.Console('error', 'platform/' + PlatformScriptNames[Index] + ': ' + Error.Message);
    end;
  end;
end;

function CallPlatformCallback(Context: TBindingContext; const Name: string; const Args: array of TJsValue): Boolean;
begin
  Result := Context.CallPlatform(Name, Args);
end;

end.

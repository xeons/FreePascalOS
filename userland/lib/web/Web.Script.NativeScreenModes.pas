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
  The natives of platform/78-screen-modes.js (the Fullscreen API and the
  Pointer Lock API): the requests to the host through the script
  environment, and the document's fullscreen element and pointer lock
  element (Web.Dom), whose change restyles (:fullscreen).
}
unit Web.Script.NativeScreenModes;

{$mode objfpc}
{$H+}

interface

uses
  Js.Objects,
  Web.Bindings.Context;

procedure DefineScreenModeNatives(Context: TBindingContext; Natives: TJsObject);

implementation

uses
  SysUtils,
  Js.Values,
  Js.Functions,
  Web.Dom,
  Web.Bindings.Types,
  Web.ScriptEnvironment;

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

function PermissionText(Context: TBindingContext; Permission: TScriptPermission): TJsValue;
begin
  case Permission of
    ScriptPermissionGranted: Result := Context.TextValue('granted');
    ScriptPermissionDenied: Result := Context.TextValue('denied');
  else
    Result := Context.TextValue('unsupported');
  end;
end;

{ fullscreenRequest(enter) -> "granted", "denied" or "unsupported" }
function NativeFullscreenRequest(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := PermissionText(Context, Context.Environment.RequestFullscreen(Context, Arg(Args, ArgCount, 0) = JsTrue));
end;

{ pointerLockRequest(lock) }
function NativePointerLockRequest(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := PermissionText(Context, Context.Environment.RequestPointerLock(Context, Arg(Args, ArgCount, 0) = JsTrue));
end;

{ The old and new element restyle (:fullscreen). }
procedure Restyle(Element: TElement);
begin
  if (Element <> nil) and Element.IsConnected then
    Element.NodeDocument.NotifyCustomElementStateChanged(Element);
end;

{ setFullscreenElement(element or null) on the context's document. }
function NativeSetFullscreenElement(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Document: TDocument;
  Old, New: TElement;
begin
  Result := JsUndefined;
  Document := Context.Document;
  New := ElementArg(Context, Args, ArgCount, 0);
  if (New <> nil) and ((New.NodeDocument <> Document) or not New.IsConnected) then
    New := nil;
  Old := Document.FullscreenElement;
  if Old = New then
    Exit;
  Document.FullscreenElement := New;
  Restyle(Old);
  Restyle(New);
end;

function NativeFullscreenElement(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := Context.WrapNode(Context.Document.FullscreenElement);
end;

function NativeSetPointerLockElement(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  New: TElement;
begin
  New := ElementArg(Context, Args, ArgCount, 0);
  if (New <> nil) and ((New.NodeDocument <> Context.Document) or not New.IsConnected) then
    New := nil;
  Context.Document.PointerLockElement := New;
  Result := JsUndefined;
end;

function NativePointerLockElement(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := Context.WrapNode(Context.Document.PointerLockElement);
end;

type
  TScreenModeNative = function(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;

const
  ScreenModeNativeCount = 6;
  ScreenModeNativeNames: array[0..ScreenModeNativeCount - 1] of string = ('fullscreenRequest', 'pointerLockRequest',
    'setFullscreenElement', 'fullscreenElement', 'setPointerLockElement', 'pointerLockElement');
  ScreenModeNativeLengths: array[0..ScreenModeNativeCount - 1] of Integer = (1, 1, 1, 0, 1, 0);
  ScreenModeNativeRoutines: array[0..ScreenModeNativeCount - 1] of TScreenModeNative = (@NativeFullscreenRequest,
    @NativePointerLockRequest, @NativeSetFullscreenElement, @NativeFullscreenElement, @NativeSetPointerLockElement,
    @NativePointerLockElement);

function ScreenModeNativeEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
begin
  Context := ContextOfRealm(R);
  try
    Result := ScreenModeNativeRoutines[Callee.Magic](Context, Args, ArgCount);
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

procedure DefineScreenModeNatives(Context: TBindingContext; Natives: TJsObject);
var
  Index: Integer;
begin
  for Index := 0 to ScreenModeNativeCount - 1 do
    Context.Engine.DefineFunction(Natives, ScreenModeNativeNames[Index], @ScreenModeNativeEntry,
      ScreenModeNativeLengths[Index], Index);
end;

end.

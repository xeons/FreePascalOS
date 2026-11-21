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
  Windows of other origins (HTML 7.2.1.3 "cross-origin objects"). The
  windows of a page and its frames are realms of one script heap, so a
  window never hands another window's global object to script of a
  different origin: wherever a window is returned (contentWindow,
  parent, top, frames[i], a message's source) WindowValueFor gives the
  global itself when the two documents are same origin, else a
  cross-origin view made in the asking realm. The view answers only
  what the standard allows across origins - window, self, frames, top,
  parent, opener, closed, length, the frames by index, location (a view
  too: setting it or href navigates, replace() navigates), postMessage,
  close, focus and blur; then, @@toStringTag, @@hasInstance and
  @@isConcatSpreadable read as undefined - and throws a SecurityError
  for anything else; it has no prototype and cannot be extended or
  changed. postMessage through a view calls the target's own and turns
  an exception from it into one of the caller's realm. Origins are
  compared as they are when asked (a frame that navigates to another
  origin gives a view from then on).
}
unit Web.Bindings.CrossOrigin;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Objects,
  Js.Functions,
  Js.Symbols,
  Js.Shapes,
  Web.Dom,
  Web.Bindings.Strings,
  Web.Bindings.Context;

type
  { A window of another origin as script of Accessor sees it. }
  TCrossOriginWindowView = class(TJsObject)
  public
    Accessor: TBindingContext;
    Target: TBindingContext;
    { postMessage, close, focus, blur and the location view, made when
      first asked for. }
    Members: array[0..4] of TJsValue;
    procedure Trace(Tracer: TJsTracer); override;
    function GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer; override;
    function DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
      ThrowOnFailure: Boolean): Integer; override;
    function HasProperty(R: TJsRealm; Key: TJsValue): Integer; override;
    function Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue; override;
    function SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer; override;
    function DeleteProperty(R: TJsRealm; Key: TJsValue): Integer; override;
    function OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean; override;
    function GetPrototype(R: TJsRealm; out Prototype: TJsObject): Boolean; override;
    function SetPrototype(R: TJsRealm; Prototype: TJsObject): Integer; override;
    function PreventExtensions(R: TJsRealm): Integer; override;
    function IsExtensible(R: TJsRealm): Integer; override;
  end;

  { The Location of a window of another origin. }
  TCrossOriginLocationView = class(TCrossOriginWindowView)
  public
    function GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer; override;
    function Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue; override;
    function SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer; override;
    function OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean; override;
  end;

{ Target's window as Accessor's script may see it: its global object
  when same origin, else a cross-origin view; null for nil. }
function WindowValueFor(Accessor, Target: TBindingContext): TJsValue;
{ Whether Accessor's script may see into Target's window. }
function SameOriginContexts(Accessor, Target: TBindingContext): Boolean;
{ The global object's index properties (window[0] ...) follow its open
  frames. }
procedure UpdateFrameIndices(Context: TBindingContext);

implementation

uses
  Js.Runtime,
  Js.Operations,
  Js.Conversions,
  Web.Origins,
  Web.Bindings.UrlResolution;

const
  MemberPostMessage = 0;
  MemberClose = 1;
  MemberFocus = 2;
  MemberBlur = 3;
  MemberLocation = 4;
  WindowNames: array[0..12] of string = ('window', 'self', 'location', 'close', 'closed', 'focus', 'blur',
    'frames', 'length', 'top', 'opener', 'parent', 'postMessage');

function SameOriginContexts(Accessor, Target: TBindingContext): Boolean;
begin
  if (Accessor = nil) or (Target = nil) then
    Exit(False);
  Result := (Accessor = Target) or DocumentsSameOrigin(Accessor.Document, Target.Document);
end;

function NewView(Accessor, Target: TBindingContext; ViewClass: TJsObjectClassType): TCrossOriginWindowView;
var
  Index: Integer;
begin
  Result := TCrossOriginWindowView(Accessor.Engine.Realm.NewObjectOfClass(ViewClass, nil, ocObject));
  Result.ObjectFlags := (Result.ObjectFlags or ObjectExotic) and not ObjectExtensible;
  Result.Accessor := Accessor;
  Result.Target := Target;
  for Index := 0 to High(Result.Members) do
    Result.Members[Index] := JsUndefined;
end;

function WindowValueFor(Accessor, Target: TBindingContext): TJsValue;
var
  Index: Integer;
begin
  if Target = nil then
    Exit(JsNull);
  if SameOriginContexts(Accessor, Target) then
    Exit(JsObjectValue(Target.Engine.GlobalObject));
  for Index := 0 to High(Accessor.CrossOriginTargets) do
    if Accessor.CrossOriginTargets[Index] = Target then
      Exit(Accessor.CrossOriginViews[Index]);
  Result := JsObjectValue(NewView(Accessor, Target, TCrossOriginWindowView));
  { A closed window keeps no roots: its views are not cached. }
  if Accessor.Closed then
    Exit;
  SetLength(Accessor.CrossOriginTargets, Length(Accessor.CrossOriginTargets) + 1);
  SetLength(Accessor.CrossOriginViews, Length(Accessor.CrossOriginViews) + 1);
  Accessor.CrossOriginTargets[High(Accessor.CrossOriginTargets)] := Target;
  Accessor.CrossOriginViews[High(Accessor.CrossOriginViews)] := Result;
end;

procedure UpdateFrameIndices(Context: TBindingContext);
var
  Global: TJsObject;
  Realm: TJsRealm;
  Index, Count: Integer;
  Child: TBindingContext;
  Name: string;
begin
  if Context.Closed then
    Exit;
  Realm := Context.Engine.Realm;
  Global := Context.Engine.GlobalObject;
  Count := Context.FrameCount;
  for Index := 0 to Count - 1 do
    Global.DefineOwnProperty(Realm, JsInteger(Index), DataDescriptor(WindowValueFor(Context, Context.FrameAt(Index)),
      PropertyConfigurable), False);
  for Index := Count to Context.FrameIndexCount - 1 do
    Global.DeleteProperty(Realm, JsInteger(Index));
  Context.FrameIndexCount := Count;
  { The frames by name (HTML 7.2.2.3, the window's named properties):
    below every other property of the window, so a name the window
    has already is left alone. }
  for Index := 0 to High(Context.FrameNameKeys) do
    Global.DeleteProperty(Realm, Realm.Intern(Context.FrameNameKeys[Index]));
  Context.FrameNameKeys := nil;
  for Index := 0 to Count - 1 do
  begin
    Child := Context.FrameAt(Index);
    Name := ValueToText(Child.Engine.Realm, Child.Singleton(SingletonWindowName));
    if (Name = '') or (Global.HasProperty(Realm, Realm.Intern(Name)) = 1) then
      Continue;
    Global.DefineOwnProperty(Realm, Realm.Intern(Name), DataDescriptor(WindowValueFor(Context, Child),
      PropertyConfigurable), False);
    SetLength(Context.FrameNameKeys, Length(Context.FrameNameKeys) + 1);
    Context.FrameNameKeys[High(Context.FrameNameKeys)] := Name;
  end;
  if Realm.HasException then
    Realm.Runtime.TakeException;
end;

function KeyText(R: TJsRealm; Key: TJsValue): string;
begin
  if JsIsString(Key) then
    Result := JsStringToText(R.Heap, JsAsString(Key))
  else
    Result := '';
end;

{ then, @@toStringTag, @@hasInstance, @@isConcatSpreadable: undefined. }
function IsQuietKey(R: TJsRealm; Key: TJsValue): Boolean;
begin
  Result := (KeyText(R, Key) = 'then') or (Key = R.Runtime.SymbolValue(wsToStringTag)) or
    (Key = R.Runtime.SymbolValue(wsHasInstance)) or (Key = R.Runtime.SymbolValue(wsIsConcatSpreadable));
end;

function Refused(View: TCrossOriginWindowView; R: TJsRealm; Key: TJsValue): TJsValue;
var
  Name: string;
begin
  Name := KeyText(R, Key);
  if Name = '' then
    Name := 'a property';
  Result := View.Accessor.ThrowDomException('SecurityError', 'Blocked a frame from accessing ' + Name +
    ' of a cross-origin frame.');
end;

{ ---- the members ---- }

function ViewOf(Callee: TJsNativeFunction): TCrossOriginWindowView;
begin
  Result := TCrossOriginWindowView(JsAsObject(Callee.Data));
end;

function CrossOriginPostMessage(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  View: TCrossOriginWindowView;
  Target: TJsObject;
  Method, Thrown, NameValue, MessageValue: TJsValue;
  Name, Message: string;
begin
  View := ViewOf(Callee);
  if View.Target.Closed then
    Exit(JsUndefined);
  Target := View.Target.Engine.GlobalObject;
  Method := Target.Get(R, R.Intern('postMessage'), JsObjectValue(Target));
  if R.HasException then
    R.Runtime.TakeException;
  if not JsIsObject(Method) then
    Exit(JsUndefined);
  Result := R.Call(Method, JsObjectValue(Target), PJsValue(Args), ArgCount);
  if not R.HasException then
    Exit(JsUndefined);
  { The target realm's error becomes one of the caller's. }
  Thrown := R.Runtime.TakeException;
  Name := 'DataCloneError';
  Message := 'postMessage failed';
  if JsIsObject(Thrown) then
  begin
    NameValue := JsAsObject(Thrown).Get(R, R.Intern('name'), Thrown);
    if R.HasException then
      R.Runtime.TakeException;
    MessageValue := JsAsObject(Thrown).Get(R, R.Intern('message'), Thrown);
    if R.HasException then
      R.Runtime.TakeException;
    if JsIsString(NameValue) then
      Name := JsStringToText(R.Heap, JsAsString(NameValue));
    if JsIsString(MessageValue) then
      Message := JsStringToText(R.Heap, JsAsString(MessageValue));
  end;
  Result := View.Accessor.ThrowDomException(Name, Message);
end;

function CrossOriginNothing(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := JsUndefined;
end;

function NavigateTarget(View: TCrossOriginWindowView; R: TJsRealm; Value: TJsValue; Replace: Boolean): Boolean;
var
  Text, Resolved: string;
  Converted: TJsValue;
begin
  Result := False;
  Converted := ToStringValue(R, Value);
  if R.HasException then
    Exit;
  Text := JsStringToText(R.Heap, JsAsString(Converted));
  if not ResolveUrlText(View.Accessor.Document, Text, Resolved) then
  begin
    View.Accessor.ThrowDomException('SyntaxError', 'Failed to set location: ''' + Text + ''' is not a valid URL.');
    Exit;
  end;
  if not View.Target.Closed then
    View.Target.Environment.Navigate(View.Target, Resolved, Replace);
  Result := True;
end;

function CrossOriginReplace(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
begin
  if ArgCount > 0 then
    Value := Args^[0]
  else
    Value := JsUndefined;
  if NavigateTarget(ViewOf(Callee), R, Value, True) then
    Result := JsUndefined
  else
    Result := JsException;
end;

function MemberFunction(View: TCrossOriginWindowView; R: TJsRealm; Slot: Integer; const Name: string;
  Callback: TJsNativeCallback; Length: Integer): TJsValue;
var
  F: TJsNativeFunction;
begin
  if View.Members[Slot] <> JsUndefined then
    Exit(View.Members[Slot]);
  F := NewNativeFunction(View.Accessor.Engine.Realm, Name, Callback, Length);
  F.Data := JsObjectValue(View);
  View.Members[Slot] := JsObjectValue(F);
  Result := View.Members[Slot];
end;

function LocationView(View: TCrossOriginWindowView): TJsValue;
var
  Location: TCrossOriginWindowView;
begin
  if View.Members[MemberLocation] <> JsUndefined then
    Exit(View.Members[MemberLocation]);
  Location := NewView(View.Accessor, View.Target, TCrossOriginLocationView);
  View.Members[MemberLocation] := JsObjectValue(Location);
  Result := View.Members[MemberLocation];
end;

{ The value of an allowed name; False when the name is not allowed. }
function WindowMember(View: TCrossOriginWindowView; R: TJsRealm; Key: TJsValue; out Value: TJsValue): Boolean;
var
  Name: string;
  Index: Integer;
  Target: TBindingContext;
begin
  Value := JsUndefined;
  Result := True;
  Target := View.Target;
  if JsIsInteger(Key) and (JsAsInteger(Key) >= 0) then
  begin
    Index := JsAsInteger(Key);
    if Index < Target.FrameCount then
    begin
      Value := WindowValueFor(View.Accessor, Target.FrameAt(Index));
      Exit;
    end;
    Exit(False);
  end;
  if IsQuietKey(R, Key) then
    Exit;
  Name := KeyText(R, Key);
  if (Name = 'window') or (Name = 'self') or (Name = 'frames') then
    Value := WindowValueFor(View.Accessor, Target)
  else if Name = 'top' then
    Value := WindowValueFor(View.Accessor, Target.TopContext)
  else if Name = 'parent' then
  begin
    if Target.ParentContext <> nil then
      Value := WindowValueFor(View.Accessor, Target.ParentContext)
    else
      Value := WindowValueFor(View.Accessor, Target);
  end
  else if Name = 'opener' then
    Value := JsNull
  else if Name = 'closed' then
    Value := JsBoolean(Target.Closed)
  else if Name = 'length' then
    Value := JsInteger(Target.FrameCount)
  else if Name = 'location' then
    Value := LocationView(View)
  else if Name = 'postMessage' then
    Value := MemberFunction(View, R, MemberPostMessage, 'postMessage', @CrossOriginPostMessage, 1)
  else if Name = 'close' then
    Value := MemberFunction(View, R, MemberClose, 'close', @CrossOriginNothing, 0)
  else if Name = 'focus' then
    Value := MemberFunction(View, R, MemberFocus, 'focus', @CrossOriginNothing, 0)
  else if Name = 'blur' then
    Value := MemberFunction(View, R, MemberBlur, 'blur', @CrossOriginNothing, 0)
  else if Target.FrameNamed(Name) <> nil then
    Value := WindowValueFor(View.Accessor, Target.FrameNamed(Name))
  else
    Result := False;
end;

{ TCrossOriginWindowView }

procedure AddKey(var Keys: TJsValueList; Key: TJsValue);
begin
  SetLength(Keys, Length(Keys) + 1);
  Keys[High(Keys)] := Key;
end;

procedure TCrossOriginWindowView.Trace(Tracer: TJsTracer);
var
  Index: Integer;
begin
  inherited Trace(Tracer);
  for Index := 0 to High(Members) do
    Tracer.MarkValue(Members[Index]);
end;

function TCrossOriginWindowView.GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer;
var
  Value: TJsValue;
begin
  Desc := DataDescriptor(JsUndefined, PropertyDefault);
  if not WindowMember(Self, R, Key, Value) then
  begin
    Refused(Self, R, Key);
    Exit(-1);
  end;
  if IsQuietKey(R, Key) then
    Exit(0);
  Desc := DataDescriptor(Value, PropertyConfigurable);
  Result := 1;
end;

function TCrossOriginWindowView.DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
  ThrowOnFailure: Boolean): Integer;
begin
  Refused(Self, R, Key);
  Result := -1;
end;

function TCrossOriginWindowView.HasProperty(R: TJsRealm; Key: TJsValue): Integer;
var
  Desc: TJsPropertyDescriptor;
begin
  Result := GetOwnProperty(R, Key, Desc);
end;

function TCrossOriginWindowView.Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue;
begin
  if not WindowMember(Self, R, Key, Result) then
    Result := Refused(Self, R, Key);
end;

function TCrossOriginWindowView.SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer;
begin
  if KeyText(R, Key) = 'location' then
  begin
    if NavigateTarget(Self, R, Value, False) then
      Exit(1);
    Exit(-1);
  end;
  Refused(Self, R, Key);
  Result := -1;
end;

function TCrossOriginWindowView.DeleteProperty(R: TJsRealm; Key: TJsValue): Integer;
begin
  Refused(Self, R, Key);
  Result := -1;
end;

function TCrossOriginWindowView.OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean;
var
  Index: Integer;
begin
  Keys := nil;
  if (Filter and KeysStrings) <> 0 then
  begin
    for Index := 0 to Target.FrameCount - 1 do
      AddKey(Keys, JsInteger(Index));
    for Index := 0 to High(WindowNames) do
      AddKey(Keys, R.Intern(WindowNames[Index]));
  end;
  if (Filter and KeysSymbols) <> 0 then
  begin
    AddKey(Keys, R.Runtime.SymbolValue(wsToStringTag));
    AddKey(Keys, R.Runtime.SymbolValue(wsHasInstance));
    AddKey(Keys, R.Runtime.SymbolValue(wsIsConcatSpreadable));
  end;
  Result := True;
end;

function TCrossOriginWindowView.GetPrototype(R: TJsRealm; out Prototype: TJsObject): Boolean;
begin
  Prototype := nil;
  Result := True;
end;

function TCrossOriginWindowView.SetPrototype(R: TJsRealm; Prototype: TJsObject): Integer;
begin
  if Prototype = nil then
    Result := 1
  else
    Result := 0;
end;

function TCrossOriginWindowView.PreventExtensions(R: TJsRealm): Integer;
begin
  Result := 0;
end;

function TCrossOriginWindowView.IsExtensible(R: TJsRealm): Integer;
begin
  Result := 1;
end;

{ TCrossOriginLocationView }

function LocationMember(View: TCrossOriginWindowView; R: TJsRealm; Key: TJsValue; out Value: TJsValue): Boolean;
begin
  Value := JsUndefined;
  Result := True;
  if IsQuietKey(R, Key) then
    Exit;
  if KeyText(R, Key) = 'replace' then
    Value := MemberFunction(View, R, MemberClose, 'replace', @CrossOriginReplace, 1)
  else if KeyText(R, Key) = 'href' then
    Value := JsUndefined
  else
    Result := False;
end;

function TCrossOriginLocationView.GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer;
var
  Value: TJsValue;
begin
  Desc := DataDescriptor(JsUndefined, PropertyDefault);
  if not LocationMember(Self, R, Key, Value) or (KeyText(R, Key) = 'href') then
  begin
    Refused(Self, R, Key);
    Exit(-1);
  end;
  if IsQuietKey(R, Key) then
    Exit(0);
  Desc := DataDescriptor(Value, PropertyConfigurable);
  Result := 1;
end;

function TCrossOriginLocationView.Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue;
begin
  { href may only be set across origins. }
  if not LocationMember(Self, R, Key, Result) or (KeyText(R, Key) = 'href') then
    Result := Refused(Self, R, Key);
end;

function TCrossOriginLocationView.SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer;
begin
  if KeyText(R, Key) = 'href' then
  begin
    if NavigateTarget(Self, R, Value, False) then
      Exit(1);
    Exit(-1);
  end;
  Refused(Self, R, Key);
  Result := -1;
end;

function TCrossOriginLocationView.OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean;
begin
  Keys := nil;
  if (Filter and KeysStrings) <> 0 then
  begin
    AddKey(Keys, R.Intern('href'));
    AddKey(Keys, R.Intern('replace'));
  end;
  Result := True;
end;

end.

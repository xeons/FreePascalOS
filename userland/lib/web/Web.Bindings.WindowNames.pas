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
  The window's named properties object (HTML Standard 7.2.2.3, WebIDL
  3.7.4): between Window.prototype and EventTarget.prototype, so
  `box` and `window.box` find <div id="box"> when nothing on the window
  or Window.prototype has that name. It is exotic: a name it answers is
  an own property that cannot be defined or deleted.

  What it answers: the first element in tree order whose id is the name
  (through the document's id map: a miss on the window costs one
  lookup). Not yet: embed, form, img and object by their name
  attribute, and a collection when several elements share the name.
  The frames by name are the window's own properties
  (Web.Bindings.CrossOrigin).
}
unit Web.Bindings.WindowNames;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Js.Objects,
  Web.Bindings.Context;

type
  TWindowNamedProperties = class(TJsObject)
  public
    Context: TBindingContext;
    function GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer; override;
    function DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
      ThrowOnFailure: Boolean): Integer; override;
    function DeleteProperty(R: TJsRealm; Key: TJsValue): Integer; override;
  end;

{ Puts the named properties object above Prototype (Window.prototype). }
procedure InstallWindowNamedProperties(Context: TBindingContext; Prototype: TJsObject);

implementation

uses
  Js.Shapes,
  Web.Dom;

function TWindowNamedProperties.GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer;
var
  Name: string;
  Document: TDocument;
  Element: TElement;
begin
  Result := inherited GetOwnProperty(R, Key, Desc);
  if (Result <> 0) or not JsIsString(Key) or (Context = nil) then
    Exit;
  Document := Context.Document;
  if Document = nil then
    Exit;
  Name := ValueToText(R, Key);
  if Name = '' then
    Exit;
  Element := Document.GetElementById(Name);
  if Element = nil then
    Exit;
  Desc := DataDescriptor(Context.WrapNode(Element), PropertyWritable or PropertyConfigurable);
  Result := 1;
end;

function TWindowNamedProperties.DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
  ThrowOnFailure: Boolean): Integer;
begin
  if ThrowOnFailure then
  begin
    R.ThrowTypeError('Cannot define a property on the window''s named properties object');
    Exit(-1);
  end;
  Result := 0;
end;

function TWindowNamedProperties.DeleteProperty(R: TJsRealm; Key: TJsValue): Integer;
var
  Desc: TJsPropertyDescriptor;
  Found: Integer;
begin
  Found := GetOwnProperty(R, Key, Desc);
  if Found < 0 then
    Exit(-1);
  if Found > 0 then
    Exit(0);
  Result := 1;
end;

procedure InstallWindowNamedProperties(Context: TBindingContext; Prototype: TJsObject);
var
  R: TJsRealm;
  Named: TWindowNamedProperties;
begin
  R := Context.Engine.Realm;
  Named := TWindowNamedProperties(R.NewObjectOfClass(TWindowNamedProperties, Prototype.Proto, ocObject));
  Named.Context := Context;
  Named.ObjectFlags := Named.ObjectFlags or ObjectExotic;
  Prototype.Proto := Named;
end;

end.

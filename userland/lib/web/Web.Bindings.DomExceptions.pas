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
  bindings/DomExceptions.webidl: DOMException (WebIDL 3.14), whose
  prototype inherits from Error.prototype. EDomException raised by the
  DOM becomes one in TBindingContext.ThrowFromException.
}
unit Web.Bindings.DomExceptions;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Bindings.Types;

{$I Web.Bindings.DomExceptions.Members.inc}

{ The legacy code of an error name (0 for names without one). }
function DomExceptionCode(const Name: string): Integer;

implementation

uses
  Web.Bindings.Context;

const
  LegacyNames: array[1..25] of string = ('IndexSizeError', '', 'HierarchyRequestError', 'WrongDocumentError',
    'InvalidCharacterError', '', 'NoModificationAllowedError', 'NotFoundError', 'NotSupportedError',
    'InUseAttributeError', 'InvalidStateError', 'SyntaxError', 'InvalidModificationError', 'NamespaceError',
    'InvalidAccessError', '', 'TypeMismatchError', 'SecurityError', 'NetworkError', 'AbortError',
    'URLMismatchError', 'QuotaExceededError', 'TimeoutError', 'InvalidNodeTypeError', 'DataCloneError');

function DomExceptionCode(const Name: string): Integer;
var
  Index: Integer;
begin
  for Index := Low(LegacyNames) to High(LegacyNames) do
    if (LegacyNames[Index] <> '') and (LegacyNames[Index] = Name) then
      Exit(Index);
  Result := 0;
end;

function DOMException_constructor(var Call: TBindingCall): TJsValue;
var
  Data: TDomExceptionData;
begin
  Data := TDomExceptionData.Create;
  Data.Message := Call.Text(0);
  Data.Name := Call.Text(1);
  Result := TBindingContext(Call.Context).ConstructedObject(Call, Data);
end;

function DOMException_get_name(var Call: TBindingCall): TJsValue;
begin
  Result := TBindingContext(Call.Context).TextValue(TDomExceptionData(Call.Target).Name);
end;

function DOMException_get_message(var Call: TBindingCall): TJsValue;
begin
  Result := TBindingContext(Call.Context).TextValue(TDomExceptionData(Call.Target).Message);
end;

function DOMException_get_code(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(DomExceptionCode(TDomExceptionData(Call.Target).Name));
end;

end.

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
  DOMException: what the DOM algorithms throw, with the standard's error
  names (WebIDL) and their legacy codes, for the script bindings to turn
  into JavaScript DOMException objects.
}
unit Web.Dom.Exceptions;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  HierarchyRequestError = 'HierarchyRequestError';
  WrongDocumentError = 'WrongDocumentError';
  InvalidCharacterError = 'InvalidCharacterError';
  NoModificationAllowedError = 'NoModificationAllowedError';
  NotFoundError = 'NotFoundError';
  NotSupportedError = 'NotSupportedError';
  InUseAttributeError = 'InUseAttributeError';
  InvalidStateError = 'InvalidStateError';
  SyntaxError = 'SyntaxError';
  NamespaceError = 'NamespaceError';
  IndexSizeError = 'IndexSizeError';

type
  EDomException = class(Exception)
  private
    FErrorName: string;
    function GetLegacyCode: Integer;
  public
    constructor CreateError(const ErrorName, Detail: string);
    { The WebIDL error name, such as "HierarchyRequestError". }
    property ErrorName: string read FErrorName;
    { The legacy code (DOMException.code), 0 for names without one. }
    property LegacyCode: Integer read GetLegacyCode;
  end;

procedure RaiseDomError(const ErrorName, Detail: string);

implementation

constructor EDomException.CreateError(const ErrorName, Detail: string);
begin
  inherited Create(ErrorName + ': ' + Detail);
  FErrorName := ErrorName;
end;

function EDomException.GetLegacyCode: Integer;
begin
  if FErrorName = IndexSizeError then
    Result := 1
  else if FErrorName = HierarchyRequestError then
    Result := 3
  else if FErrorName = WrongDocumentError then
    Result := 4
  else if FErrorName = InvalidCharacterError then
    Result := 5
  else if FErrorName = NoModificationAllowedError then
    Result := 7
  else if FErrorName = NotFoundError then
    Result := 8
  else if FErrorName = NotSupportedError then
    Result := 9
  else if FErrorName = InUseAttributeError then
    Result := 10
  else if FErrorName = InvalidStateError then
    Result := 11
  else if FErrorName = SyntaxError then
    Result := 12
  else if FErrorName = NamespaceError then
    Result := 14
  else
    Result := 0;
end;

procedure RaiseDomError(const ErrorName, Detail: string);
begin
  raise EDomException.CreateError(ErrorName, Detail);
end;

end.

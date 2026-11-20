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
  bindings/Urls.webidl: URL and URLSearchParams (URL Standard 6) over
  libhttp's parser, accessors and form encoding. A URL's searchParams
  belong to the URL (the URL's native object owns them and they write
  their changes back into its query); a URLSearchParams made by script
  owns itself.
}
unit Web.Bindings.Urls;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Bindings.Types;

{$I Web.Bindings.Urls.Members.inc}

implementation

uses
  SysUtils,
  Url.Records,
  Url.Parser,
  Url.Accessors,
  Url.FormEncoding,
  Url.SearchParams,
  Web.Bindings.Context;

type
  TUrlData = class
  private
    procedure ParamsChanged(Sender: TUrlSearchParams);
  public
    Url: TUrlRecord;
    Params: TUrlSearchParams;
    constructor Create(const AUrl: TUrlRecord);
    destructor Destroy; override;
    { The query changed (href, search): the params follow. }
    procedure QueryChanged;
  end;

constructor TUrlData.Create(const AUrl: TUrlRecord);
begin
  inherited Create;
  Url := AUrl;
  Params := TUrlSearchParams.Create(Url.Query);
  Params.OnChanged := @ParamsChanged;
end;

destructor TUrlData.Destroy;
begin
  Params.Free;
  inherited Destroy;
end;

procedure TUrlData.ParamsChanged(Sender: TUrlSearchParams);
var
  Query: string;
begin
  Query := Params.ToString;
  Url.HasQuery := Query <> '';
  Url.Query := Query;
end;

procedure TUrlData.QueryChanged;
begin
  if Url.HasQuery then
    Params.Assign(Url.Query)
  else
    Params.Assign('');
end;

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

function ThisUrl(const Call: TBindingCall): TUrlData; inline;
begin
  Result := TUrlData(Call.Target);
end;

{ The URL parser on Input against Base when given. }
function ParseWithBase(const Call: TBindingCall; out Url: TUrlRecord): Boolean;
var
  Base: TUrlRecord;
begin
  if Call.Present(1) then
  begin
    if not ParseUrl(Call.Text(1), Base) then
      Exit(False);
    Result := ParseUrl(Call.Text(0), Base, Url);
  end
  else
    Result := ParseUrl(Call.Text(0), Url);
end;

function URL_constructor(var Call: TBindingCall): TJsValue;
var
  Url: TUrlRecord;
begin
  if not ParseWithBase(Call, Url) then
    raise EBindingTypeError.Create('''' + Call.Text(0) + ''' is not a valid URL');
  Result := Context(Call).ConstructedObject(Call, TUrlData.Create(Url));
end;

function URL_parse(var Call: TBindingCall): TJsValue;
var
  Url: TUrlRecord;
begin
  if not ParseWithBase(Call, Url) then
    Exit(JsNull);
  Result := Context(Call).WrapObject(TUrlData.Create(Url), InterfaceURL, True, JsUndefined);
end;

function URL_canParse(var Call: TBindingCall): TJsValue;
var
  Url: TUrlRecord;
begin
  Result := JsBoolean(ParseWithBase(Call, Url));
end;

function URL_get_href(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(GetHref(ThisUrl(Call).Url));
end;

function URL_set_href(var Call: TBindingCall): TJsValue;
var
  Changed: TUrlRecord;
begin
  Changed := ThisUrl(Call).Url;
  if not SetHref(Changed, Call.Text(0)) then
    raise EBindingTypeError.Create('''' + Call.Text(0) + ''' is not a valid URL');
  ThisUrl(Call).Url := Changed;
  ThisUrl(Call).QueryChanged;
  Result := JsUndefined;
end;

function URL_toJSON(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(GetHref(ThisUrl(Call).Url));
end;

function URL_get_origin(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(GetOrigin(ThisUrl(Call).Url));
end;

function URL_get_protocol(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(GetProtocol(ThisUrl(Call).Url));
end;

function URL_set_protocol(var Call: TBindingCall): TJsValue;
begin
  SetProtocol(ThisUrl(Call).Url, Call.Text(0));
  Result := JsUndefined;
end;

function URL_get_username(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(GetUsername(ThisUrl(Call).Url));
end;

function URL_set_username(var Call: TBindingCall): TJsValue;
begin
  SetUsername(ThisUrl(Call).Url, Call.Text(0));
  Result := JsUndefined;
end;

function URL_get_password(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(GetPassword(ThisUrl(Call).Url));
end;

function URL_set_password(var Call: TBindingCall): TJsValue;
begin
  SetPassword(ThisUrl(Call).Url, Call.Text(0));
  Result := JsUndefined;
end;

function URL_get_host(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(GetHost(ThisUrl(Call).Url));
end;

function URL_set_host(var Call: TBindingCall): TJsValue;
begin
  SetHost(ThisUrl(Call).Url, Call.Text(0));
  Result := JsUndefined;
end;

function URL_get_hostname(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(GetHostname(ThisUrl(Call).Url));
end;

function URL_set_hostname(var Call: TBindingCall): TJsValue;
begin
  SetHostname(ThisUrl(Call).Url, Call.Text(0));
  Result := JsUndefined;
end;

function URL_get_port(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(GetPort(ThisUrl(Call).Url));
end;

function URL_set_port(var Call: TBindingCall): TJsValue;
begin
  SetPort(ThisUrl(Call).Url, Call.Text(0));
  Result := JsUndefined;
end;

function URL_get_pathname(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(GetPathname(ThisUrl(Call).Url));
end;

function URL_set_pathname(var Call: TBindingCall): TJsValue;
begin
  SetPathname(ThisUrl(Call).Url, Call.Text(0));
  Result := JsUndefined;
end;

function URL_get_search(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(GetSearch(ThisUrl(Call).Url));
end;

function URL_set_search(var Call: TBindingCall): TJsValue;
begin
  SetSearch(ThisUrl(Call).Url, Call.Text(0));
  ThisUrl(Call).QueryChanged;
  Result := JsUndefined;
end;

function URL_get_searchParams(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisUrl(Call).Params, InterfaceURLSearchParams, False, Call.This);
end;

function URL_get_hash(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(GetHash(ThisUrl(Call).Url));
end;

function URL_set_hash(var Call: TBindingCall): TJsValue;
begin
  SetHash(ThisUrl(Call).Url, Call.Text(0));
  Result := JsUndefined;
end;

{ URLSearchParams }

function ThisParams(const Call: TBindingCall): TUrlSearchParams; inline;
begin
  Result := TUrlSearchParams(Call.Target);
end;

function URLSearchParams_constructor(var Call: TBindingCall): TJsValue;
var
  Params: TUrlSearchParams;
  Init: PBindingValue;
  Index: Integer;
begin
  Init := @Call.Arguments[0];
  Params := TUrlSearchParams.Create;
  try
    case Init^.Kind of
      bvSequence:
        for Index := 0 to High(Init^.Items) do
        begin
          if Length(Init^.Items[Index].Items) <> 2 then
            raise EBindingTypeError.Create('each pair must have a name and a value');
          Params.Append(Init^.Items[Index].Items[0].Text, Init^.Items[Index].Items[1].Text);
        end;
      bvRecord:
        for Index := 0 to High(Init^.Keys) do
          Params.Append(Init^.Keys[Index], Init^.Items[Index].Text);
      bvString:
        Params.Assign(Init^.Text);
    end;
  except
    Params.Free;
    raise;
  end;
  Result := Context(Call).ConstructedObject(Call, Params);
end;

function URLSearchParams_get_size(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisParams(Call).Count);
end;

function URLSearchParams_append(var Call: TBindingCall): TJsValue;
begin
  ThisParams(Call).Append(Call.Text(0), Call.Text(1));
  Result := JsUndefined;
end;

function URLSearchParams_delete(var Call: TBindingCall): TJsValue;
begin
  if Call.Present(1) then
    ThisParams(Call).Delete(Call.Text(0), Call.Text(1))
  else
    ThisParams(Call).Delete(Call.Text(0));
  Result := JsUndefined;
end;

function URLSearchParams_get(var Call: TBindingCall): TJsValue;
var
  Value: string;
begin
  if not ThisParams(Call).Get(Call.Text(0), Value) then
    Exit(JsNull);
  Result := Context(Call).TextValue(Value);
end;

function URLSearchParams_getAll(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).StringArray(ThisParams(Call).GetAll(Call.Text(0)));
end;

function URLSearchParams_has(var Call: TBindingCall): TJsValue;
begin
  if Call.Present(1) then
    Result := JsBoolean(ThisParams(Call).Has(Call.Text(0), Call.Text(1)))
  else
    Result := JsBoolean(ThisParams(Call).Has(Call.Text(0)));
end;

function URLSearchParams_set(var Call: TBindingCall): TJsValue;
begin
  ThisParams(Call).SetValue(Call.Text(0), Call.Text(1));
  Result := JsUndefined;
end;

function URLSearchParams_sort(var Call: TBindingCall): TJsValue;
begin
  ThisParams(Call).Sort;
  Result := JsUndefined;
end;

function URLSearchParams_pairAt(var Call: TBindingCall): TJsValue;
var
  Index: Integer;
  Pair: TNameValuePair;
begin
  Index := Call.Int(0);
  if (Index < 0) or (Index >= ThisParams(Call).Count) then
    Exit(JsUndefined);
  Pair := ThisParams(Call).Pairs[Index];
  Result := Context(Call).StringArray([Pair.Name, Pair.Value]);
end;

function URLSearchParams_stringifier(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisParams(Call).ToString);
end;

end.

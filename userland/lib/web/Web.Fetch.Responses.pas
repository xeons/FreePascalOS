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
  Fetch responses (Fetch Standard section 2.2.6): the type (basic, cors,
  default, error, opaque, opaque-redirect), status and status message,
  the full header list (the engine always reads the internal response:
  an opaque image still decodes), the URL list, the MIME type extracted
  from Content-Type and the one sniffed, and for scripts the header
  names a CORS-filtered response would show. A network error is a
  response of type error with the reason in ErrorText.
}
unit Web.Fetch.Responses;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Url.Records,
  Http.HeaderFields,
  Web.Fetch.MimeTypes;

type
  TFetchResponseType = (ResponseTypeBasic, ResponseTypeCors, ResponseTypeDefault, ResponseTypeError,
    ResponseTypeOpaque, ResponseTypeOpaqueRedirect);

  TFetchResponse = class
  private
    FHeaders: THttpHeaders;
  public
    ResponseType: TFetchResponseType;
    Status: Integer;
    StatusText: string;
    UrlList: array of TUrlRecord;
    { From Content-Type (Valid False when there was none). }
    MimeType: TMimeType;
    { After sniffing (the essence), or MimeType's essence. }
    ComputedEssence: string;
    { Network errors: why. }
    ErrorText: string;
    { The body came from the HTTP cache. }
    FromCache: Boolean;
    { The protocol: "http/1.1", "h2", "h3", or the scheme for others. }
    Protocol: string;
    { Header names a script may read (CORS-safelisted plus exposed). }
    ExposedHeaderNames: TStringArray;
    constructor Create;
    destructor Destroy; override;
    class function NetworkError(const Reason: string): TFetchResponse;
    function IsNetworkError: Boolean;
    function Url: TUrlRecord;
    function HasUrl: Boolean;
    { Status 200 to 299. }
    function Ok: Boolean;
    { The charset parameter of the MIME type, or ''. }
    function Charset: string;
    property Headers: THttpHeaders read FHeaders;
  end;

function ResponseTypeName(ResponseType: TFetchResponseType): string;

implementation

constructor TFetchResponse.Create;
begin
  inherited Create;
  FHeaders := THttpHeaders.Create;
  ResponseType := ResponseTypeDefault;
  Status := 200;
  StatusText := '';
end;

destructor TFetchResponse.Destroy;
begin
  FHeaders.Free;
  inherited Destroy;
end;

class function TFetchResponse.NetworkError(const Reason: string): TFetchResponse;
begin
  Result := TFetchResponse.Create;
  Result.ResponseType := ResponseTypeError;
  Result.Status := 0;
  Result.ErrorText := Reason;
end;

function TFetchResponse.IsNetworkError: Boolean;
begin
  Result := ResponseType = ResponseTypeError;
end;

function TFetchResponse.Url: TUrlRecord;
begin
  if Length(UrlList) = 0 then
    Exit(EmptyUrl);
  Result := UrlList[High(UrlList)];
end;

function TFetchResponse.HasUrl: Boolean;
begin
  Result := Length(UrlList) > 0;
end;

function TFetchResponse.Ok: Boolean;
begin
  Result := (Status >= 200) and (Status <= 299);
end;

function TFetchResponse.Charset: string;
begin
  if not MimeParameter(MimeType, 'charset', Result) then
    Result := '';
end;

function ResponseTypeName(ResponseType: TFetchResponseType): string;
const
  Names: array[TFetchResponseType] of string = ('basic', 'cors', 'default', 'error', 'opaque', 'opaqueredirect');
begin
  Result := Names[ResponseType];
end;

end.

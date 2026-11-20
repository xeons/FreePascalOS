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
  A request's content: its length when known (HTTP/1.1 then sends
  Content-Length, else the chunked coding; HTTP/2 a content-length when
  known), read in pieces as it is sent, and rewound when the request
  has to go again (a 307 or 308 redirect, a connection that broke
  before the response, a 401 answered with credentials).

    THttpBytesBody     bytes in memory (a form, JSON)
    THttpStreamBody    a TStream (a file), from where it stands
    THttpCallbackBody  pieces a routine produces (streamed uploads)

  Plain Pascal (the RTL and Classes), checked on the host by
  tools/HttpTest.
}
unit Http.RequestBodies;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils;

type
  THttpRequestBody = class
  public
    { Bytes in all, or -1 when unknown. }
    function Length: Int64; virtual; abstract;
    { Up to Count bytes; 0 at the end, -1 on failure. }
    function Read(Buffer: Pointer; Count: Integer): Integer; virtual; abstract;
    { Back to the start; False if it cannot be read again. }
    function Rewind: Boolean; virtual; abstract;
    { The media type ('' for none). }
    function ContentType: string; virtual;
  end;

  THttpBytesBody = class(THttpRequestBody)
  private
    FData: TBytes;
    FPosition: Integer;
    FContentType: string;
  public
    constructor Create(const Data: TBytes; const MediaType: string = ''); overload;
    constructor Create(const Text: string; const MediaType: string = ''); overload;
    function Length: Int64; override;
    function Read(Buffer: Pointer; Count: Integer): Integer; override;
    function Rewind: Boolean; override;
    function ContentType: string; override;
  end;

  THttpStreamBody = class(THttpRequestBody)
  private
    FStream: TStream;
    FOwnsStream: Boolean;
    FStart: Int64;
    FContentType: string;
  public
    constructor Create(Stream: TStream; OwnsStream: Boolean; const MediaType: string = '');
    destructor Destroy; override;
    function Length: Int64; override;
    function Read(Buffer: Pointer; Count: Integer): Integer; override;
    function Rewind: Boolean; override;
    function ContentType: string; override;
  end;

  { Fills Buffer with up to Count bytes; returns how many, 0 at the end,
    -1 on failure. Rewind is asked for again with Position 0. }
  THttpBodyProducer = function(Context: Pointer; Buffer: Pointer; Count: Integer): Integer;
  THttpBodyRestart = function(Context: Pointer): Boolean;

  THttpCallbackBody = class(THttpRequestBody)
  private
    FProducer: THttpBodyProducer;
    FRestart: THttpBodyRestart;
    FContext: Pointer;
    FLength: Int64;
    FContentType: string;
  public
    { Restart may be nil (the body cannot go twice). }
    constructor Create(Producer: THttpBodyProducer; Restart: THttpBodyRestart; Context: Pointer; Size: Int64;
      const MediaType: string = '');
    function Length: Int64; override;
    function Read(Buffer: Pointer; Count: Integer): Integer; override;
    function Rewind: Boolean; override;
    function ContentType: string; override;
  end;

implementation

function THttpRequestBody.ContentType: string;
begin
  Result := '';
end;

constructor THttpBytesBody.Create(const Data: TBytes; const MediaType: string);
begin
  inherited Create;
  FData := Data;
  FContentType := MediaType;
end;

constructor THttpBytesBody.Create(const Text: string; const MediaType: string);
begin
  inherited Create;
  FData := nil;
  SetLength(FData, System.Length(Text));
  if Text <> '' then
    Move(Text[1], FData[0], System.Length(Text));
  FContentType := MediaType;
end;

function THttpBytesBody.Length: Int64;
begin
  Result := System.Length(FData);
end;

function THttpBytesBody.Read(Buffer: Pointer; Count: Integer): Integer;
begin
  Result := System.Length(FData) - FPosition;
  if Result > Count then
    Result := Count;
  if Result > 0 then
  begin
    Move(FData[FPosition], Buffer^, Result);
    Inc(FPosition, Result);
  end;
end;

function THttpBytesBody.Rewind: Boolean;
begin
  FPosition := 0;
  Result := True;
end;

function THttpBytesBody.ContentType: string;
begin
  Result := FContentType;
end;

constructor THttpStreamBody.Create(Stream: TStream; OwnsStream: Boolean; const MediaType: string);
begin
  inherited Create;
  FStream := Stream;
  FOwnsStream := OwnsStream;
  FContentType := MediaType;
  try
    FStart := Stream.Position;
  except
    FStart := -1;
  end;
end;

destructor THttpStreamBody.Destroy;
begin
  if FOwnsStream then
    FStream.Free;
  inherited Destroy;
end;

function THttpStreamBody.Length: Int64;
begin
  if FStart < 0 then
    Exit(-1);
  try
    Result := FStream.Size - FStart;
  except
    Result := -1;
  end;
end;

function THttpStreamBody.Read(Buffer: Pointer; Count: Integer): Integer;
begin
  try
    Result := FStream.Read(Buffer^, Count);
  except
    Result := -1;
  end;
end;

function THttpStreamBody.Rewind: Boolean;
begin
  if FStart < 0 then
    Exit(False);
  try
    FStream.Position := FStart;
    Result := True;
  except
    Result := False;
  end;
end;

function THttpStreamBody.ContentType: string;
begin
  Result := FContentType;
end;

constructor THttpCallbackBody.Create(Producer: THttpBodyProducer; Restart: THttpBodyRestart; Context: Pointer;
  Size: Int64; const MediaType: string);
begin
  inherited Create;
  FProducer := Producer;
  FRestart := Restart;
  FContext := Context;
  FLength := Size;
  FContentType := MediaType;
end;

function THttpCallbackBody.Length: Int64;
begin
  Result := FLength;
end;

function THttpCallbackBody.Read(Buffer: Pointer; Count: Integer): Integer;
begin
  Result := FProducer(FContext, Buffer, Count);
end;

function THttpCallbackBody.Rewind: Boolean;
begin
  Result := Assigned(FRestart) and FRestart(FContext);
end;

function THttpCallbackBody.ContentType: string;
begin
  Result := FContentType;
end;

end.

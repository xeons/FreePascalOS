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
  Where a response's content goes as it arrives, piece by piece, so a
  program can show or parse it before the end:

    THttpBodySink      the base: Write each piece, Finish at the end
    THttpMemorySink    collects it (Text, Bytes), up to a limit
    THttpDiscardSink   drops it
    THttpStreamSink    writes it to a TStream (a file)
    THttpCallbackSink  hands each piece to a method

  Sinks chain: a decoder (Http.ContentDecoding) is a sink in front of
  another. A failed Write stops the transfer; the sink says why
  (ErrorCode for a system error, DamagedData for coded content that
  does not decode, ErrorText).

  Plain Pascal (the RTL and Classes), checked on the host by
  tools/HttpTest.
}
unit Http.BodySinks;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils;

type
  THttpBodySink = class
  protected
    FWritten: Int64;
    FErrorCode: LongInt;
    FDamagedData: Boolean;
    FErrorText: string;
  public
    function Write(Data: Pointer; Count: PtrUInt): Boolean; virtual; abstract;
    { The content ended; False if it ended too soon (a decoder's data
      was cut). }
    function Finish: Boolean; virtual;
    { Bytes that reached this sink. }
    property Written: Int64 read FWritten;
    property ErrorCode: LongInt read FErrorCode;
    property DamagedData: Boolean read FDamagedData;
    property ErrorText: string read FErrorText;
  end;

  THttpMemorySink = class(THttpBodySink)
  private
    FData: TBytes;
    FLimit: Int64;
    function GetText: string;
    function GetBytes: TBytes;
  public
    { Limit: the most it keeps (0: no limit); more fails the write. }
    constructor Create(Limit: Int64 = 0);
    function Write(Data: Pointer; Count: PtrUInt): Boolean; override;
    procedure Clear;
    property Text: string read GetText;
    property Bytes: TBytes read GetBytes;
  end;

  THttpDiscardSink = class(THttpBodySink)
  public
    function Write(Data: Pointer; Count: PtrUInt): Boolean; override;
  end;

  THttpStreamSink = class(THttpBodySink)
  private
    FStream: TStream;
  public
    { The stream is not freed with the sink. }
    constructor Create(Stream: TStream);
    function Write(Data: Pointer; Count: PtrUInt): Boolean; override;
  end;

  THttpDataEvent = procedure(Data: Pointer; Count: PtrUInt) of object;

  THttpCallbackSink = class(THttpBodySink)
  private
    FOnData: THttpDataEvent;
  public
    constructor Create(OnData: THttpDataEvent);
    function Write(Data: Pointer; Count: PtrUInt): Boolean; override;
  end;

implementation

function THttpBodySink.Finish: Boolean;
begin
  Result := True;
end;

constructor THttpMemorySink.Create(Limit: Int64);
begin
  inherited Create;
  FLimit := Limit;
end;

function THttpMemorySink.Write(Data: Pointer; Count: PtrUInt): Boolean;
var
  Capacity: Int64;
begin
  if (FLimit > 0) and (FWritten + Int64(Count) > FLimit) then
  begin
    FErrorText := 'the content is larger than allowed';
    Exit(False);
  end;
  if FWritten + Int64(Count) > Length(FData) then
  begin
    Capacity := Length(FData) * 2;
    if Capacity < 4096 then
      Capacity := 4096;
    while Capacity < FWritten + Int64(Count) do
      Capacity := Capacity * 2;
    SetLength(FData, Capacity);
  end;
  if Count > 0 then
    Move(Data^, FData[FWritten], Count);
  Inc(FWritten, Count);
  Result := True;
end;

procedure THttpMemorySink.Clear;
begin
  FWritten := 0;
end;

function THttpMemorySink.GetText: string;
begin
  Result := '';
  SetLength(Result, FWritten);
  if FWritten > 0 then
    Move(FData[0], Result[1], FWritten);
end;

function THttpMemorySink.GetBytes: TBytes;
begin
  Result := Copy(FData, 0, FWritten);
end;

function THttpDiscardSink.Write(Data: Pointer; Count: PtrUInt): Boolean;
begin
  Inc(FWritten, Count);
  Result := True;
end;

constructor THttpStreamSink.Create(Stream: TStream);
begin
  inherited Create;
  FStream := Stream;
end;

function THttpStreamSink.Write(Data: Pointer; Count: PtrUInt): Boolean;
begin
  try
    FStream.WriteBuffer(Data^, Count);
    Inc(FWritten, Count);
    Result := True;
  except
    on Error: Exception do
    begin
      FErrorText := Error.Message;
      Result := False;
    end;
  end;
end;

constructor THttpCallbackSink.Create(OnData: THttpDataEvent);
begin
  inherited Create;
  FOnData := OnData;
end;

function THttpCallbackSink.Write(Data: Pointer; Count: PtrUInt): Boolean;
begin
  FOnData(Data, Count);
  Inc(FWritten, Count);
  Result := True;
end;

end.

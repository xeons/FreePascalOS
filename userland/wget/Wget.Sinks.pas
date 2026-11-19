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
  Where a response body goes as it arrives:

    TOutputSink     into the output file (or standard output)
    TDiscardSink    nowhere (the body of a redirection or an error, read
                    so the connection can take the next request)
    TInflatingSink  decoded (Content-Encoding gzip, x-gzip or deflate,
                    through libcompression's TInflater) into another sink

  Write and Finish return a system error code, or SinkDamagedData when
  the encoded body does not decode (or ends before its data does).
}
unit Wget.Sinks;

{$mode objfpc}
{$H+}

interface

uses
  Compression.Inflater,
  Wget.Files;

const
  SinkDamagedData = -1;

type
  TBodySink = class
  protected
    FWritten: Int64;
  public
    function Write(Data: Pointer; Length: PtrUInt): LongInt; virtual; abstract;
    { The body has ended. }
    function Finish: LongInt; virtual;
    { Bytes that reached the end of the chain. }
    property Written: Int64 read FWritten;
  end;

  TOutputSink = class(TBodySink)
  private
    FTarget: ^TOutputTarget;
  public
    constructor Create(var Target: TOutputTarget);
    function Write(Data: Pointer; Length: PtrUInt): LongInt; override;
  end;

  TDiscardSink = class(TBodySink)
  public
    function Write(Data: Pointer; Length: PtrUInt): LongInt; override;
  end;

  TInflatingSink = class(TBodySink)
  private
    FNext: TBodySink;
    FInflater: TInflater;
  public
    { Next is not freed with it. }
    constructor Create(Next: TBodySink; Gzip: Boolean);
    destructor Destroy; override;
    function Write(Data: Pointer; Length: PtrUInt): LongInt; override;
    function Finish: LongInt; override;
  end;

{ True for a Content-Encoding TInflatingSink decodes. }
function EncodingCanBeDecoded(const Encoding: string): Boolean;
function EncodingIsGzip(const Encoding: string): Boolean;

implementation

uses
  Abi.SystemCalls,
  Compression.Formats;

const
  InflateBufferSize = 32 * 1024;

function EncodingIsGzip(const Encoding: string): Boolean;
begin
  Result := (Encoding = 'gzip') or (Encoding = 'x-gzip');
end;

function EncodingCanBeDecoded(const Encoding: string): Boolean;
begin
  Result := EncodingIsGzip(Encoding) or (Encoding = 'deflate');
end;

function TBodySink.Finish: LongInt;
begin
  Result := ErrorNone;
end;

constructor TOutputSink.Create(var Target: TOutputTarget);
begin
  inherited Create;
  FTarget := @Target;
end;

function TOutputSink.Write(Data: Pointer; Length: PtrUInt): LongInt;
begin
  Result := WriteOutput(FTarget^, Data, Length);
  if Result = ErrorNone then
    FWritten := FWritten + Int64(Length);
end;

function TDiscardSink.Write(Data: Pointer; Length: PtrUInt): LongInt;
begin
  FWritten := FWritten + Int64(Length);
  Result := ErrorNone;
end;

constructor TInflatingSink.Create(Next: TBodySink; Gzip: Boolean);
begin
  inherited Create;
  FNext := Next;
  if Gzip then
    FInflater := TInflater.Create(FormatGzip)
  else
    FInflater := TInflater.Create(FormatAutomatic);
end;

destructor TInflatingSink.Destroy;
begin
  FInflater.Free;
  inherited Destroy;
end;

function TInflatingSink.Write(Data: Pointer; Length: PtrUInt): LongInt;
var
  Buffer: array[0..InflateBufferSize - 1] of Byte;
  Produced: SizeInt;
  Outcome: TInflateResult;
begin
  Result := ErrorNone;
  if (Length = 0) or FInflater.Finished then
    Exit;
  FInflater.SetInput(Data, Length);
  repeat
    Outcome := FInflater.Decompress(@Buffer[0], SizeOf(Buffer), Produced);
    if Outcome = InflateFailed then
      Exit(SinkDamagedData);
    if Produced > 0 then
    begin
      Result := FNext.Write(@Buffer[0], Produced);
      if Result <> ErrorNone then
        Exit;
      FWritten := FWritten + Produced;
    end;
  until Outcome <> InflateOutputFull;
end;

function TInflatingSink.Finish: LongInt;
begin
  if not FInflater.Finished then
    Exit(SinkDamagedData);
  Result := FNext.Finish;
end;

end.
